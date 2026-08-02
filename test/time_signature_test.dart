import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/abc_exporter.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// A score with [time] as its `<time>` block (omit for none) and two bars of
/// four quarter notes — the shape of a tune whose bars are right and whose
/// signature may not be.
String _score({String? time}) => '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>4</divisions>
        <key><fifths>1</fifths><mode>minor</mode></key>
        ${time ?? ''}
        <clef><sign>G</sign><line>2</line></clef>
      </attributes>
      ${'<note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration><type>quarter</type></note>' * 4}
    </measure>
    <measure number="2">
      ${'<note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration><type>quarter</type></note>' * 4}
    </measure>
  </part>
</score-partwise>''';

const _twoFour = '<time><beats>2</beats><beat-type>4</beat-type></time>';

void main() {
  final parser = MusicXmlParser();

  group('setTimeSignature', () {
    test('rewrites an existing signature and leaves note values alone', () {
      final before = parser.parse(_score(time: _twoFour));
      final after = parser.parse(MeasureXmlEditor.setTimeSignature(
          _score(time: _twoFour),
          beats: 2,
          beatType: 2));

      expect(after.beatsPerMeasure, 2);
      expect(after.beatType, 2);
      // Same notes, same durations, same everything else.
      expect(after.measures.length, before.measures.length);
      for (var i = 0; i < after.measures.length; i++) {
        expect(after.measures[i].actualUnits, before.measures[i].actualUnits);
      }
      expect(after.keyFifths, before.keyFifths);
      expect(after.divisions, before.divisions);
    });

    test('clears the bar-total warnings a wrong signature caused', () {
      // Four quarters per bar labelled 2/4: every bar reads as double length.
      final wrong = parser.parse(_score(time: _twoFour));
      expect(wrong.flaggedMeasureNumbers, isNotEmpty);

      final fixed = parser.parse(MeasureXmlEditor.setTimeSignature(
          _score(time: _twoFour),
          beats: 2,
          beatType: 2));
      expect(fixed.flaggedMeasureNumbers, isEmpty);
    });

    test('adds a signature to a score that has none, before the clef', () {
      final xml = MeasureXmlEditor.setTimeSignature(_score(),
          beats: 6, beatType: 8);
      final parsed = parser.parse(xml);
      expect(parsed.beatsPerMeasure, 6);
      expect(parsed.beatType, 8);
      // MusicXML fixes the order inside <attributes>; a <time> after <clef>
      // makes the document invalid even though our own parser wouldn't care.
      expect(xml.indexOf('<time>'), lessThan(xml.indexOf('<clef>')));
    });

    test('is idempotent', () {
      final once = MeasureXmlEditor.setTimeSignature(_score(time: _twoFour),
          beats: 3, beatType: 4);
      final twice =
          MeasureXmlEditor.setTimeSignature(once, beats: 3, beatType: 4);
      expect(twice, once);
      expect('<time>'.allMatches(twice), hasLength(1));
    });

    test('rejects a meter that is not one', () {
      expect(
          () => MeasureXmlEditor.setTimeSignature(_score(time: _twoFour),
              beats: 0, beatType: 4),
          throwsArgumentError);
      expect(
          () => MeasureXmlEditor.setTimeSignature(_score(time: _twoFour),
              beats: 4, beatType: 0),
          throwsArgumentError);
    });

    test('leaves a mid-piece meter change alone', () {
      // The app's model carries one meter per piece, so only the first <time>
      // is ours to rewrite — clobbering the rest would destroy a distinction
      // nothing else in the app can currently make.
      final withChange = _score(time: _twoFour).replaceFirst(
          '<measure number="2">',
          '<measure number="2"><attributes>'
              '<time><beats>3</beats><beat-type>4</beat-type></time>'
              '</attributes>');
      final out = MeasureXmlEditor.setTimeSignature(withChange,
          beats: 2, beatType: 2);
      expect(out, contains('<beats>2</beats><beat-type>2</beat-type>'));
      expect(out, contains('<beats>3</beats><beat-type>4</beat-type>'));
    });
  });

  group('copyWithTime', () {
    test('re-reads the same bars under a different meter', () {
      final piece = parser.parse(_score(time: _twoFour));
      expect(piece.flaggedMeasureNumbers, isNotEmpty);

      final asCutTime = piece.copyWithTime(beatsPerMeasure: 2, beatType: 2);
      expect(asCutTime.flaggedMeasureNumbers, isEmpty);
      // Nothing but the meter moved.
      expect(asCutTime.measures, same(piece.measures));
      expect(asCutTime.keyFifths, piece.keyFifths);
      expect(piece.beatType, 4, reason: 'the original must not be mutated');
    });
  });

  group('the mislabelled-cut-time case', () {
    // The shape The Wellerman imported in: four quarters in every bar under a
    // 2/4 signature.
    test('exports as 2/2 once relabelled', () {
      final fixed = parser.parse(MeasureXmlEditor.setTimeSignature(
          _score(time: _twoFour),
          beats: 2,
          beatType: 2));
      final abc = AbcExporter.export(fixed, title: 'The Wellerman');
      expect(abc, contains('M: 2/2'));
      expect(abc, isNot(contains('M: 2/4')));
    });
  });

  group('every bundled fixture', () {
    test('keeps its own meter when relabelled to it', () {
      // A no-op relabel must be a no-op on the parse, whatever shape the file's
      // <attributes> happen to be in.
      for (final file in Directory('assets/fixtures')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.xml'))) {
        final xml = file.readAsStringSync();
        final before = parser.parse(xml);
        final after = parser.parse(MeasureXmlEditor.setTimeSignature(xml,
            beats: before.beatsPerMeasure, beatType: before.beatType));
        expect(after.beatsPerMeasure, before.beatsPerMeasure,
            reason: file.path);
        expect(after.beatType, before.beatType, reason: file.path);
        expect(after.measures.length, before.measures.length,
            reason: file.path);
      }
    });
  });
}

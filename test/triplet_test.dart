import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/services/abc_exporter.dart';
import 'package:violin_practice_companion/services/chord_editor.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_beamer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/tuplet_editor.dart';
import 'package:violin_practice_companion/services/tuplet_repair.dart';

/// A note as MusicXML: [type] `eighth`/`quarter`, [dur] in divisions, and a
/// triplet mark when [triplet].
String _n(String step, String type, int dur, {bool triplet = false}) =>
    '<note><pitch><step>$step</step><octave>4</octave></pitch>'
    '<duration>$dur</duration><type>$type</type>'
    '${triplet ? '<time-modification><actual-notes>3</actual-notes>'
        '<normal-notes>2</normal-notes></time-modification>' : ''}'
    '</note>';

/// A 3/4 score of [bars] (each a string of `<note>`s), at [divisions].
String _score(List<String> bars, {int divisions = 6}) {
  final buf = StringBuffer('''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
''');
  for (var i = 0; i < bars.length; i++) {
    buf.write('<measure number="${i + 1}">');
    if (i == 0) {
      buf.write('<attributes><divisions>$divisions</divisions>'
          '<key><fifths>1</fifths></key>'
          '<time><beats>3</beats><beat-type>4</beat-type></time>'
          '<clef><sign>G</sign><line>2</line></clef></attributes>');
    }
    buf.write('${bars[i]}</measure>\n');
  }
  buf.write('</part>\n</score-partwise>');
  return buf.toString();
}

/// A minuet's bar 15, at divisions 6: a triplet of eighths, then two
/// quarters — three beats only if the triplet counts as one.
final _realTripletBar = '${_n('A', 'eighth', 2, triplet: true)}'
    '${_n('B', 'eighth', 2, triplet: true)}'
    '${_n('C', 'eighth', 2, triplet: true)}'
    '${_n('D', 'quarter', 6)}${_n('F', 'quarter', 6)}';

/// A fingering "4" read as a triplet over two of four eighths: the bar is
/// three beats only WITHOUT it (the shape of the Christmas medley's bar 9).
final _falseTripletBar = '${_n('A', 'quarter', 6)}'
    '${_n('A', 'eighth', 2, triplet: true)}${_n('B', 'eighth', 2, triplet: true)}'
    '${_n('A', 'eighth', 3)}${_n('G', 'eighth', 3)}';

final _plainBar = '${_n('G', 'quarter', 6)}' * 3;

NoteEvent _note(NoteValue v, {bool triplet = false, bool chord = false}) =>
    NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: v,
      dotted: false,
      isRest: false,
      isChord: chord,
      tuplet: triplet ? TupletEditor.triplet : null,
    );

void main() {
  final parser = MusicXmlParser();

  group('the model counts triplets', () {
    test('a real triplet makes its bar add up', () {
      final p = parser.parse(_score([_realTripletBar, _plainBar]));
      final notes = p.measures[0].notes;
      expect(notes.first.tuplet, (actual: 3, normal: 2));
      expect(notes[3].tuplet, isNull);
      expect(p.measures[0].actualUnits, 24);
      expect(p.flaggedMeasureNumbers, isEmpty);
    });

    test('playback gives a triplet eighth two-thirds of an eighth', () {
      final p = parser.parse(_score([_realTripletBar]));
      final midi = MidiGenerator.forTest().generate(p, 60);
      // At 60 bpm a quarter is 1s: three triplet eighths share it.
      final t = midi.measureNoteTimings.first;
      expect(t[0].$2 - t[0].$1, closeTo(1 / 3, 1e-9));
      expect(t[3].$1, closeTo(1.0, 1e-9)); // the first quarter lands on beat 2
      expect(midi.totalDurationSeconds, closeTo(3.0, 1e-9));
    });

    test('tupletGroups finds whole groups, and stops at a plain note', () {
      final notes = [
        _note(NoteValue.eighth, triplet: true),
        _note(NoteValue.eighth, triplet: true),
        _note(NoteValue.eighth, triplet: true),
        _note(NoteValue.eighth, triplet: true),
        _note(NoteValue.eighth, triplet: true, chord: true),
        _note(NoteValue.quarter),
      ];
      expect(tupletGroups(notes), [(0, 3), (3, 5)]);
    });

    test('a chord member takes its primary note\'s triplet', () {
      final out = ChordEditor.normalize([
        _note(NoteValue.eighth, triplet: true),
        _note(NoteValue.eighth, chord: true),
      ]);
      expect(out[1].tuplet, TupletEditor.triplet);
    });
  });

  group('the measure editor', () {
    test('writes a triplet back, bracket and all', () {
      final src = _score([_realTripletBar]);
      final notes = parser.parse(src).measures[0].notes;
      final xml = MeasureXmlEditor.replaceMeasureNotes(src, 1, notes, 6);
      expect(RegExp('<time-modification>').allMatches(xml).length, 3);
      expect(xml, contains('<tuplet type="start" bracket="yes"/>'));
      expect(xml, contains('<tuplet type="stop"/>'));
      final again = parser.parse(xml);
      expect(again.measures[0].actualUnits, 24);
      expect(again.measures[0].notes.take(3).map((n) => n.tuplet),
          everyElement((actual: 3, normal: 2)));
    });

    test('a saved triplet is beamed again', () {
      // The editor writes no beams; the repository's rebeam on save does.
      final src = _score([_realTripletBar]);
      final notes = parser.parse(src).measures[0].notes;
      final xml = MusicXmlBeamer.rebeam(
          MeasureXmlEditor.replaceMeasureNotes(src, 1, notes, 6));
      final beams = RegExp(r'<beam number="1">(\w+)</beam>')
          .allMatches(xml)
          .map((m) => m.group(1))
          .toList();
      expect(beams, ['begin', 'continue', 'end']);
    });

    test('counts a score finer when a triplet has no whole duration', () {
      // Divisions 2 (an eighth is 1): a triplet eighth would be 2/3.
      final src = _score([
        '${_n('A', 'quarter', 2)}' * 3,
        '${_n('B', 'eighth', 1)}' * 3 + '${_n('D', 'quarter', 2)}' * 2,
      ], divisions: 2);
      final bar2 = parser.parse(src).measures[1].notes;
      final made = TupletEditor.toggle(bar2, 0);
      final xml = MeasureXmlEditor.replaceMeasureNotes(src, 2, made, 2);
      expect(xml, contains('<divisions>6</divisions>'));
      final p = parser.parse(xml);
      expect(p.measures[0].actualUnits, 24, reason: 'bar 1 rescaled too');
      expect(p.measures[1].actualUnits, 24);
      expect(p.flaggedMeasureNumbers, isEmpty);
    });

    test('trusts the document\'s divisions over a draft\'s', () {
      // The caller says 6 (a draft already rescaled); the file says 2.
      final src = _score(['${_n('A', 'quarter', 2)}' * 3], divisions: 2);
      final notes = parser.parse(src).measures[0].notes;
      final xml = MeasureXmlEditor.replaceMeasureNotes(src, 1, notes, 6);
      expect(parser.parse(xml).measures[0].actualUnits, 24);
      expect(xml, contains('<duration>2</duration>'));
    });

    test('the toggle makes three like notes a triplet, and undoes it', () {
      final notes = [
        _note(NoteValue.eighth),
        _note(NoteValue.eighth),
        _note(NoteValue.eighth),
        _note(NoteValue.quarter),
      ];
      expect(TupletEditor.blockedReason(notes, 0), isNull);
      expect(TupletEditor.blockedReason(notes, 1), isNotNull,
          reason: 'B, C and a quarter are not alike');
      final made = TupletEditor.toggle(notes, 0);
      expect(made.take(3).every((n) => n.tuplet != null), isTrue);
      expect(made[3].tuplet, isNull);
      expect(unitsOf(made), 16); // a quarter of triplets + a quarter
      // Undo from any note of the group.
      final undone = TupletEditor.toggle(made, 2);
      expect(undone.every((n) => n.tuplet == null), isTrue);
    });
  });

  group('TupletRepair', () {
    test('keeps a triplet that makes its bar add up', () {
      final src = _score([_realTripletBar, _plainBar]);
      expect(TupletRepair.repair(src), src);
    });

    test('drops a triplet whose bar adds up only without it', () {
      final out = TupletRepair.repair(_score([_falseTripletBar, _plainBar]));
      expect(out, isNot(contains('time-modification')));
      final p = parser.parse(out);
      expect(p.measures[0].actualUnits, 24);
      expect(p.flaggedMeasureNumbers, isEmpty);
    });

    test('leaves a bar that adds up neither way', () {
      // A triplet, and a quarter too few: damage of some other kind.
      final src = _score([
        '${_n('A', 'eighth', 2, triplet: true)}' * 3 + _n('D', 'quarter', 6),
      ]);
      expect(TupletRepair.repair(src), src);
    });
  });

  test('ABC export writes a triplet as (3', () {
    final abc = AbcExporter.export(parser.parse(_score([_realTripletBar])),
        title: 't');
    expect(abc, contains('(3'));
  });
}

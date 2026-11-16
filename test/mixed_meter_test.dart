import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/abc_exporter.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/meter_repair.dart';
import 'package:violin_practice_companion/services/musicxml_beamer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// One bar of a synthetic score: [quarters] quarter notes (or [eighths]
/// eighth notes), and the `<time>` written in it, if any.
typedef _Bar = ({int quarters, int eighths, String? time});

_Bar q(int quarters, [String? time]) =>
    (quarters: quarters, eighths: 0, time: time);
_Bar e(int eighths, [String? time]) =>
    (quarters: 0, eighths: eighths, time: time);

String _time(String t) {
  final [b, bt] = t.split('/');
  return '<time><beats>$b</beats><beat-type>$bt</beat-type></time>';
}

/// A one-part score of [bars]. Divisions 2, so an eighth is 1. Bar 1 holds
/// an OMR-style split `<attributes>`: divisions alone, then key and clef.
String _score(List<_Bar> bars) {
  final buf = StringBuffer('''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
''');
  for (var i = 0; i < bars.length; i++) {
    final b = bars[i];
    buf.write('<measure number="${i + 1}">');
    if (i == 0) {
      buf.write('<attributes><divisions>2</divisions></attributes>'
          '<attributes><key><fifths>1</fifths></key>'
          '${b.time == null ? '' : _time(b.time!)}'
          '<clef><sign>G</sign><line>2</line></clef></attributes>');
    } else if (b.time != null) {
      buf.write('<attributes>${_time(b.time!)}</attributes>');
    }
    buf.write('<note><pitch><step>A</step><octave>4</octave></pitch>'
            '<duration>2</duration><type>quarter</type></note>' *
        b.quarters);
    buf.write('<note><pitch><step>A</step><octave>4</octave></pitch>'
            '<duration>1</duration><type>eighth</type></note>' *
        b.eighths);
    buf.write('</measure>\n');
  }
  buf.write('</part>\n</score-partwise>');
  return buf.toString();
}

/// Where the meter changes, as `{measureNumber: 'b/bt'}` (bar 1 included).
Map<int, String> _changes(ParsedPiece p) {
  final ms = p.meters;
  return {
    for (var i = 0; i < ms.length; i++)
      if (i == 0 || ms[i] != ms[i - 1]) p.measures[i].number: '${ms[i]}',
  };
}

void main() {
  final parser = MusicXmlParser();

  group('parser', () {
    test('reads a time signature in any bar as a change there', () {
      final p = parser.parse(_score([q(3, '3/4'), q(3), q(4, '4/4'), q(4)]));
      expect(p.openingMeter, const Meter(3, 4));
      expect(p.measures[2].timeChange, const Meter(4, 4));
      expect(p.measures[1].timeChange, isNull);
      expect(_changes(p), {1: '3/4', 3: '4/4'});
      expect(p.hasMeterChanges, isTrue);
      expect(p.meterAtNumber(4), const Meter(4, 4));
    });

    test('a score with no time signature is in 4/4', () {
      final p = parser.parse(_score([q(4), q(4)]));
      expect(p.openingMeter, const Meter(4, 4));
      expect(p.hasMeterChanges, isFalse);
    });
  });

  group('bar check', () {
    test('a whole-bar rest fills its bar, whatever its type', () {
      // No <type> (MuseScore, the scanner) and "whole" in 3/4 (Finale).
      final src = _score([q(3, '3/4'), q(0), q(0), q(3)])
          .replaceFirst('<measure number="2">',
              '<measure number="2"><note><rest measure="yes"/><duration>6</duration></note>')
          .replaceFirst('<measure number="3">',
              '<measure number="3"><note><rest measure="yes"/><duration>6</duration><type>whole</type></note>');
      final p = parser.parse(src);
      expect(p.flaggedMeasureNumbers, isEmpty);
      expect(p.measures[1].notes.single.noteValue, NoteValue.half);
      expect(p.measures[1].notes.single.dotted, isTrue);
    });

    test('checks every bar against its own meter', () {
      final p = parser.parse(
          _score([q(3, '3/4'), q(3), q(4, '4/4'), q(4), q(3), q(4)]));
      // Only bar 5 — three beats in the 4/4 stretch — is wrong.
      expect(p.flaggedMeasureNumbers, {5});
    });

    test('copyWithTimeChangeAt asks "what if the meter changed here"', () {
      final p = parser.parse(_score([q(3, '3/4'), q(3), q(4), q(4)]));
      expect(p.flaggedMeasureNumbers, {3, 4});
      final trial = p.copyWithTimeChangeAt(2, const Meter(4, 4));
      expect(trial.flaggedMeasureNumbers, isEmpty);
      expect(trial.meterSpanFrom(2).toList(), [2, 3]);
      // And removing it again restores the original reading.
      expect(trial.copyWithTimeChangeAt(2, null).flaggedMeasureNumbers, {3, 4});
      // Index 0 sets the opening meter.
      expect(p.copyWithTimeChangeAt(0, const Meter(4, 4)).openingMeter,
          const Meter(4, 4));
    });
  });

  group('MeasureXmlEditor', () {
    String withBarRests(String xml, List<int> bars) => xml.replaceAllMapped(
        RegExp(r'(<measure number="(\d+)">(?:<attributes>.*?</attributes>)*)'),
        (m) => bars.contains(int.parse(m[2]!))
            ? '${m[1]}<note><rest measure="yes"/><duration>6</duration></note>'
            : m[0]!);

    test('a meter change resizes the whole-bar rests it governs', () {
      // Bars 1–2 rest in 3/4, then music; bar 1 becomes 4/4.
      final src = withBarRests(_score([q(0, '3/4'), q(0), q(4), q(4)]), [1, 2]);
      final xml = MeasureXmlEditor.setTimeChange(src, 1, beats: 4, beatType: 4);
      expect(RegExp(r'<duration>8</duration></note>').allMatches(xml).length, 2);
      final p = parser.parse(xml);
      expect(p.flaggedMeasureNumbers, isEmpty);
      expect(p.measures[1].notes.single.noteValue, NoteValue.whole);
    });

    test('deleting the bar a meter changes on keeps the change', () {
      final src = _score([q(4, '4/4'), q(4), q(3, '3/4'), q(3), q(3)]);
      final p = parser.parse(MeasureXmlEditor.deleteMeasure(src, 3));
      expect(_changes(p), {1: '4/4', 3: '3/4'});
    });

    test('setTimeChange inserts a change at a bar without one', () {
      final xml = MeasureXmlEditor.setTimeChange(
          _score([q(3, '3/4'), q(3), q(4), q(4)]), 3,
          beats: 4, beatType: 4);
      expect(_changes(parser.parse(xml)), {1: '3/4', 3: '4/4'});
    });

    test('setTimeChange on bar 1 writes the opening meter, even when the '
        'only <time> is later', () {
      // A scan cropped below its opening system: the first <time> is mid-piece.
      final xml = MeasureXmlEditor.setTimeChange(
          _score([q(3), q(3), q(4, '3/4'), q(4)]), 1,
          beats: 3, beatType: 4);
      final p = parser.parse(xml);
      expect(p.measures[0].timeChange, const Meter(3, 4));
      // Inserted into the block with the key and clef, between them.
      expect(xml, contains('</key><time><beats>3</beats>'
          '<beat-type>4</beat-type></time><clef>'));
    });

    test('setTimeChange rewrites an existing change in place', () {
      final xml = MeasureXmlEditor.setTimeChange(
          _score([q(3, '3/4'), q(3), q(4, '3/4'), q(4)]), 3,
          beats: 4, beatType: 4);
      expect(_changes(parser.parse(xml)), {1: '3/4', 3: '4/4'});
      expect(RegExp('<time>').allMatches(xml).length, 2);
    });

    test('removeTimeChange lets the bar carry on in the meter before it', () {
      final xml = MeasureXmlEditor.removeTimeChange(
          _score([q(3, '3/4'), q(3), q(4, '4/4'), q(4)]), 3);
      expect(_changes(parser.parse(xml)), {1: '3/4'});
      // The block held only the time, so it goes too.
      expect(RegExp('<attributes>').allMatches(xml).length, 2);
    });

    test('changing the only <time>, written late, keeps the opening meter',
        () {
      // A scan cropped below its opening system states its meter only at
      // bar 3, so that <time> is also read as the opening meter. Relabelling
      // bar 3 must not re-meter bars 1-2.
      final src = _score([q(3), q(3), q(4, '3/4'), q(4)]);
      expect(parser.parse(src).openingMeter, const Meter(3, 4));
      final changed = parser.parse(MeasureXmlEditor.setTimeChange(src, 3,
          beats: 4, beatType: 4));
      expect(_changes(changed), {1: '3/4', 3: '4/4'});
      expect(changed.flaggedMeasureNumbers, isEmpty);
      final removed =
          parser.parse(MeasureXmlEditor.removeTimeChange(src, 3));
      expect(_changes(removed), {1: '3/4'});
    });

    test('removeTimeChange never removes the opening meter', () {
      final src = _score([q(3, '3/4'), q(3)]);
      expect(MeasureXmlEditor.removeTimeChange(src, 1), src);
    });
  });

  group('MeterRepair', () {
    test('a score whose meters fit its bars is unchanged', () {
      final src = _score([q(3, '3/4'), q(3), q(3), q(4, '4/4'), q(4), q(4)]);
      expect(MeterRepair.repair(src), src);
    });

    test('corrects misread digits from the bars under them', () {
      // Bar 3 starts four-beat bars, but was read as 3/4; bar 6 is a one-bar
      // 2/4 read as 2/2-length "3/4" — wrong either way, and not a pickup.
      final p = parser.parse(MeterRepair.repair(_score([
        q(3, '3/4'), q(3), q(4, '3/4'), q(4), q(4), q(2, '3/4'), q(4), q(4),
        q(4),
      ])));
      expect(_changes(p), {1: '3/4', 3: '4/4', 6: '2/4', 7: '4/4'});
      expect(p.flaggedMeasureNumbers, isEmpty);
    });

    test('a pickup under its own time signature keeps it', () {
      // Barbara Allen: a 3-beat pickup, then bars of 3/2.
      final src = _score([q(3, '3/2'), q(6), q(6), q(6), q(3)]);
      expect(MeterRepair.repair(src), src);
      // And a new section's pickup into a meter change.
      final mid = _score([q(3, '3/4'), q(3), q(3), q(2, '4/4'), q(4), q(4)]);
      expect(MeterRepair.repair(mid), mid);
    });

    test('finds an unmarked change after a run of bars', () {
      final p = parser.parse(MeterRepair.repair(
          _score([q(4, '4/4'), q(4), q(4), q(3), q(3), q(3), q(4), q(4), q(4)])));
      expect(_changes(p), {1: '4/4', 4: '3/4', 7: '4/4'});
    });

    test('a single odd bar is damage, not a change of meter', () {
      final src =
          _score([q(4, '4/4'), q(4), q(3), q(4), q(2), q(2), q(4), q(4)]);
      expect(MeterRepair.repair(src), src);
      expect(parser.parse(src).flaggedMeasureNumbers, {3, 5, 6});
    });

    test('damaged bars neither count toward nor break a run', () {
      // Bar 5 is two bars merged (7 beats); the 3/4 still starts at bar 3.
      final p = parser.parse(MeterRepair.repair(_score(
          [q(4, '4/4'), q(4), q(3), q(3), q(7), q(3), q(3)])));
      expect(_changes(p), {1: '4/4', 3: '3/4'});
    });

    test('with no time signature at all, the first meter opens the piece', () {
      // A one-beat pickup, then 3/4: the opening meter goes into bar 1.
      final p = parser.parse(
          MeterRepair.repair(_score([q(1), q(3), q(3), q(3), q(2)])));
      expect(_changes(p), {1: '3/4'});
      expect(p.flaggedMeasureNumbers, isEmpty); // pickup + final bar pair up
    });

    test('a written 6/8 that fits its bars is kept, not made 3/4', () {
      final src = _score([e(6, '6/8'), e(6), e(6), e(6)]);
      expect(MeterRepair.repair(src), src);
    });

    test('an empty bar under a misread time takes the meter after it', () {
      // A multi-measure rest read as 7/4, then bars of 3/4.
      final p = parser.parse(MeterRepair.repair(
          _score([q(0, '7/4'), q(3), q(3), q(3), q(4, '4/4'), q(4)])));
      expect(_changes(p), {1: '3/4', 5: '4/4'});
      // One bar after it is too little to overrule the digits.
      final src = _score([q(0, '4/4'), q(3), q(4, '4/4'), q(4)]);
      expect(_changes(parser.parse(MeterRepair.repair(src)))[1], '4/4');
    });

    test('a bar of whole-bar rest is no evidence for its meter', () {
      // The recogniser writes a multi-measure rest as bars of <rest
      // measure="yes"/>, as long as the (misread) meter it was given.
      final src = _score([q(0, '4/4'), q(0), q(3), q(3), q(3)]).replaceAllMapped(
          RegExp(r'(<measure number="[12]">(?:<attributes>.*?</attributes>)*)'),
          (m) => '${m[1]}<note><rest measure="yes"/><duration>8</duration></note>');
      final p = parser.parse(MeterRepair.repair(src));
      expect(_changes(p), {1: '3/4'});
    });

    test('a written time that restates the meter in force is removed', () {
      final xml = MeterRepair.repair(
          _score([q(3, '3/4'), q(3), q(3, '3/4'), q(3)]));
      expect(RegExp('<time>').allMatches(xml).length, 1);
    });
  });

  group('per-bar meter elsewhere', () {
    test('ABC export writes an inline meter change', () {
      final abc = AbcExporter.export(
          parser.parse(_score([q(3, '3/4'), q(3), q(4, '4/4'), q(4)])),
          title: 't');
      expect(abc, contains('M: 3/4'));
      expect(abc, contains('[M:4/4]'));
    });

    test('the beamer beams each bar by its own meter', () {
      // Six eighths after a 4/4 bar: under 6/8 they group 3 + 3; read in the
      // opening 4/4 they would group 4 + 2.
      final xml = MusicXmlBeamer.rebeam(_score([e(8, '4/4'), e(6, '6/8')]));
      final bar2 = xml.substring(xml.indexOf('<measure number="2"'));
      final beams = RegExp(r'<beam number="1">(\w+)</beam>')
          .allMatches(bar2)
          .map((m) => m.group(1))
          .toList();
      expect(beams, ['begin', 'continue', 'end', 'begin', 'continue', 'end']);
    });
  });
}

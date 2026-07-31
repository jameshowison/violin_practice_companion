import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Four bars: 1 carries the attributes, 2 opens a repeated strain that 3 closes
/// (and 3 states a chord), 4 is plain. Enough to exercise every carry-over rule.
String _score({String extra3 = ''}) => '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>4</divisions>
        <key><fifths>2</fifths><mode>major</mode></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
        <clef><sign>G</sign><line>2</line></clef>
      </attributes>
      <harmony><root><root-step>A</root-step></root><kind>major</kind></harmony>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
    <measure number="2">
      <barline location="left"><bar-style>heavy-light</bar-style><repeat direction="forward"/></barline>
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
    <measure number="3">
      <harmony><root><root-step>E</root-step></root><kind>major</kind></harmony>
      <note><pitch><step>E</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>$extra3
      <barline location="right"><bar-style>light-heavy</bar-style><repeat direction="backward"/></barline>
    </measure>
    <measure number="4">
      <note><pitch><step>F</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
  </part>
</score-partwise>''';

void main() {
  final parser = MusicXmlParser();

  group('MeasureXmlEditor.deleteMeasure', () {
    test('removes the bar and renumbers the rest consecutively', () {
      final out = parser.parse(MeasureXmlEditor.deleteMeasure(_score(), 2));
      expect(out.measures.map((m) => m.number), [1, 2, 3]);
      expect(out.measures.map((m) => m.notes.single.pitch),
          ['C4', 'E4', 'F4']); // D4's bar is gone
    });

    test('deleting the first bar keeps the key, time and divisions', () {
      final out = parser.parse(MeasureXmlEditor.deleteMeasure(_score(), 1));
      expect(out.divisions, 4);
      expect(out.keyFifths, 2);
      expect(out.beatsPerMeasure, 4);
      expect(out.beatType, 4);
      expect(out.measures.first.notes.single.pitch, 'D4');
      expect(out.measures.map((m) => m.number), [1, 2, 3]);
    });

    test('a deleted |: moves to the next bar, a :| to the previous', () {
      // Bar 2 opens the strain; deleting it hands |: to what was bar 3.
      final noStart = parser.parse(MeasureXmlEditor.deleteMeasure(_score(), 2));
      expect(noStart.measures[1].repeatStart, isTrue);
      expect(noStart.measures[1].repeatEnd, isTrue);

      // Bar 3 closes it; deleting it hands :| back to bar 2 (which keeps its |:).
      final noEnd = parser.parse(MeasureXmlEditor.deleteMeasure(_score(), 3));
      expect(noEnd.measures[1].repeatStart, isTrue);
      expect(noEnd.measures[1].repeatEnd, isTrue);
    });

    test('the deleted bar\'s chord carries to the next bar', () {
      // Bar 3 introduces E; bar 4 states no chord of its own, so after deleting
      // bar 3 the E must still be labelled — not silently revert to bar 1's A.
      final out = parser.parse(MeasureXmlEditor.deleteMeasure(_score(), 3));
      expect(out.measures.last.notes.single.chordSymbol, 'E');
    });

    test('a chord the next bar states itself is not overridden', () {
      final out = parser.parse(MeasureXmlEditor.deleteMeasure(_score(), 1));
      // Old bar 2 stated no chord, so bar 1's A (still sounding) carries in…
      expect(out.measures[0].notes.single.chordSymbol, 'A');
      // …but old bar 3's own E is left alone.
      expect(out.measures[1].notes.single.chordSymbol, 'E');
    });

    test('an existing repeat is not doubled up', () {
      // Give bar 3 its own |: as well, then delete bar 2 (also a |:).
      final withBoth = _score().replaceFirst(
          '<measure number="3">',
          '<measure number="3">'
              '<barline location="left"><bar-style>heavy-light</bar-style>'
              '<repeat direction="forward"/></barline>');
      final xml = MeasureXmlEditor.deleteMeasure(withBoth, 2);
      expect(RegExp('direction="forward"').allMatches(xml).length, 1);
    });

    test('throws on an unknown measure and on the last remaining one', () {
      expect(() => MeasureXmlEditor.deleteMeasure(_score(), 99),
          throwsArgumentError);
      const single = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name/></score-part></part-list>
  <part id="P1"><measure number="1">
    <note><rest/><duration>16</duration><type>whole</type></note>
  </measure></part>
</score-partwise>''';
      expect(
          () => MeasureXmlEditor.deleteMeasure(single, 1), throwsArgumentError);
    });

    test('a pickup measure keeps number 0 while the rest renumber', () {
      const withPickup = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name/></score-part></part-list>
  <part id="P1">
    <measure number="0">
      <attributes><divisions>4</divisions></attributes>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><type>quarter</type></note>
    </measure>
    <measure number="1">
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
    <measure number="2">
      <note><pitch><step>E</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
    <measure number="3">
      <note><pitch><step>F</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
  </part>
</score-partwise>''';
      final out = parser.parse(MeasureXmlEditor.deleteMeasure(withPickup, 2));
      expect(out.measures.map((m) => m.number), [0, 1, 2]);
      expect(out.measures.map((m) => m.notes.single.pitch),
          ['C4', 'D4', 'F4']); // E4's bar is gone, the pickup is untouched
    });
  });

  group('sectionsAfterMeasureDelete', () {
    test('markers after the deleted bar shift back, earlier ones do not', () {
      final out = sectionsAfterMeasureDelete(const [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 9, startNote: 2),
      ], 5);
      expect(out, const [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 8, startNote: 2),
      ]);
    });

    test('a marker on the deleted bar slides onto the replacing bar', () {
      final out = sectionsAfterMeasureDelete(const [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 9, startNote: 3),
      ], 9);
      // B survives, now starting at the bar line of what follows.
      expect(out, const [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 9),
      ]);
    });

    test('a one-measure section disappears with its measure', () {
      final out = sectionsAfterMeasureDelete(const [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 5),
        Section(label: 'C', startMeasure: 6),
      ], 5);
      // B had only bar 5; C takes over bar 5 after the shift.
      expect(out, const [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'C', startMeasure: 5),
      ]);
    });
  });
}

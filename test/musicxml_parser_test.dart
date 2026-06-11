import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

void main() {
  final parser = MusicXmlParser();

  const simpleXml = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>4</divisions>
        <key><fifths>2</fifths><mode>major</mode></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
    </measure>
    <measure number="2">
      <note><rest/><duration>2</duration><type>half</type></note>
      <note><pitch><step>A</step><octave>5</octave></pitch><duration>2</duration><type>half</type></note>
    </measure>
    <measure number="3">
      <note><pitch><step>F</step><octave>4</octave><alter>1</alter></pitch><duration>2</duration><type>half</type><dot/></note>
    </measure>
  </part>
</score-partwise>''';

  test('parses key signature', () {
    final piece = parser.parse(simpleXml);
    expect(piece.keyFifths, 2);
    expect(piece.keyMode, KeyMode.major);
    expect(piece.keySignature, 'D');
  });

  test('parses divisions and time signature', () {
    final piece = parser.parse(simpleXml);
    expect(piece.divisions, 4);
    expect(piece.beatsPerMeasure, 4);
    expect(piece.beatType, 4);
  });

  test('parses measure count', () {
    final piece = parser.parse(simpleXml);
    expect(piece.measures.length, 3);
  });

  test('parses whole note pitch and MIDI', () {
    final piece = parser.parse(simpleXml);
    final note = piece.measures[0].notes[0];
    expect(note.pitch, 'D4');
    expect(note.midiNumber, 62); // D4 = MIDI 62
    expect(note.noteValue, NoteValue.whole);
    expect(note.isRest, false);
    expect(note.dotted, false);
  });

  test('parses rest', () {
    final piece = parser.parse(simpleXml);
    final rest = piece.measures[1].notes[0];
    expect(rest.isRest, true);
    expect(rest.noteValue, NoteValue.half);
  });

  test('parses dotted note', () {
    final piece = parser.parse(simpleXml);
    final note = piece.measures[2].notes[0];
    expect(note.dotted, true);
    expect(note.pitch, 'F#4');
    expect(note.midiNumber, 66); // F#4 = MIDI 66
  });

  test('parses high A MIDI correctly', () {
    final piece = parser.parse(simpleXml);
    final note = piece.measures[1].notes[1];
    expect(note.midiNumber, 81); // A5 = MIDI 81
  });
}

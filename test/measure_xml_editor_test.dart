import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

const _baseXml = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>4</divisions>
        <key><fifths>2</fifths><mode>major</mode></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
  </part>
</score-partwise>''';

void main() {
  final parser = MusicXmlParser();

  test('replaceMeasureNotes round-trips pitch/duration/dot/rest/fingering', () {
    final notes = <NoteEvent>[
      const NoteEvent(
          pitch: 'D4',
          midiNumber: 62,
          octave: 4,
          noteValue: NoteValue.quarter,
          dotted: false,
          isRest: false),
      const NoteEvent(
          pitch: 'F#4',
          midiNumber: 66,
          octave: 4,
          noteValue: NoteValue.half,
          dotted: true,
          isRest: false),
      const NoteEvent(
          pitch: 'A4',
          midiNumber: 69,
          octave: 4,
          noteValue: NoteValue.eighth,
          dotted: false,
          isRest: false,
          scoreFinger: 2),
      const NoteEvent(
          pitch: 'R',
          midiNumber: 0,
          octave: 4,
          noteValue: NoteValue.eighth,
          dotted: false,
          isRest: true),
    ];

    final newXml = MeasureXmlEditor.replaceMeasureNotes(_baseXml, 1, notes, 4);
    final parsed = parser.parse(newXml);

    // Attributes survived.
    expect(parsed.divisions, 4);
    expect(parsed.keyFifths, 2);
    expect(parsed.beatsPerMeasure, 4);

    final out = parsed.measures.single.notes;
    expect(out.length, 4);

    expect(out[0].pitch, 'D4');
    expect(out[0].noteValue, NoteValue.quarter);
    expect(out[0].dotted, isFalse);

    expect(out[1].pitch, 'F#4');
    expect(out[1].noteValue, NoteValue.half);
    expect(out[1].dotted, isTrue);
    expect(out[1].midiNumber, 66);

    expect(out[2].pitch, 'A4');
    expect(out[2].noteValue, NoteValue.eighth);
    expect(out[2].scoreFinger, 2);

    expect(out[3].isRest, isTrue);
    expect(out[3].noteValue, NoteValue.eighth);
  });

  test('displayAccidental round-trips through serialize → parse', () {
    final notes = <NoteEvent>[
      // Courtesy natural on a C in D major (alter 0, but a visible ♮).
      const NoteEvent(
          pitch: 'C5',
          midiNumber: 72,
          octave: 5,
          noteValue: NoteValue.eighth,
          dotted: false,
          isRest: false,
          displayAccidental: 'natural'),
      // No explicit sign: follows the key signature.
      const NoteEvent(
          pitch: 'B4',
          midiNumber: 71,
          octave: 4,
          noteValue: NoteValue.eighth,
          dotted: false,
          isRest: false),
    ];

    final newXml = MeasureXmlEditor.replaceMeasureNotes(_baseXml, 1, notes, 4);

    // The accidental element is emitted only for the note that has one.
    final doc = XmlDocument.parse(newXml);
    final accidentals = doc.findAllElements('accidental').toList();
    expect(accidentals.length, 1);
    expect(accidentals.single.innerText, 'natural');

    final out = parser.parse(newXml).measures.single.notes;
    expect(out[0].pitch, 'C5');
    expect(out[0].displayAccidental, 'natural');
    expect(out[1].pitch, 'B4');
    expect(out[1].displayAccidental, isNull);
  });

  test('parser reads <accidental> from source XML', () {
    // Mirrors gavotte m.9: a courtesy natural on C in a sharp key.
    const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>V</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes><divisions>4</divisions>
        <key><fifths>1</fifths><mode>major</mode></key>
        <time><beats>2</beats><beat-type>2</beat-type></time></attributes>
      <note><pitch><step>C</step><octave>5</octave></pitch><duration>2</duration>
        <type>eighth</type><accidental>natural</accidental></note>
      <note><pitch><step>B</step><octave>4</octave></pitch><duration>2</duration>
        <type>eighth</type></note>
    </measure>
  </part>
</score-partwise>''';
    final out = MusicXmlParser().parse(xml).measures.single.notes;
    expect(out[0].displayAccidental, 'natural');
    expect(out[1].displayAccidental, isNull);
  });

  test('replaceMeasureNotes preserves <attributes> element', () {
    final newXml = MeasureXmlEditor.replaceMeasureNotes(
      _baseXml,
      1,
      [
        const NoteEvent(
            pitch: 'G4',
            midiNumber: 67,
            octave: 4,
            noteValue: NoteValue.whole,
            dotted: false,
            isRest: false),
      ],
      4,
    );
    final doc = XmlDocument.parse(newXml);
    expect(doc.findAllElements('attributes').length, 1);
    expect(doc.findAllElements('divisions').single.innerText, '4');
  });

  test('buildSingleMeasurePreviewXml is valid and carries attributes', () {
    const parsed = ParsedPiece(
      keySignature: 'D',
      keyFifths: 2,
      keyMode: KeyMode.major,
      divisions: 4,
      beatsPerMeasure: 4,
      beatType: 4,
      measures: [],
    );
    final xml = MeasureXmlEditor.buildSingleMeasurePreviewXml(
      [
        const NoteEvent(
            pitch: 'F#5',
            midiNumber: 78,
            octave: 5,
            noteValue: NoteValue.quarter,
            dotted: false,
            isRest: false),
      ],
      parsed,
    );

    final doc = XmlDocument.parse(xml); // throws if malformed
    expect(doc.findAllElements('divisions').single.innerText, '4');
    expect(doc.findAllElements('fifths').single.innerText, '2');
    expect(doc.findAllElements('clef').length, 1);
    expect(doc.findAllElements('measure').length, 1);

    // The single note re-parses correctly.
    final reparsed = MusicXmlParser().parse(xml);
    expect(reparsed.measures.single.notes.single.pitch, 'F#5');
  });
}

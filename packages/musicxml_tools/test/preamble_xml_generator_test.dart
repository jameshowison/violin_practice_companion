import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:musicxml_tools/musicxml_tools.dart';

String _score(String attributesXml) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<score-partwise version="3.1">'
    '<part-list><score-part id="P1"><part-name/></score-part></part-list>'
    '<part id="P1"><measure number="1">$attributesXml'
    '<note><pitch><step>D</step><octave>5</octave></pitch>'
    '<duration>2</duration><type>quarter</type></note>'
    '</measure></part></score-partwise>';

XmlElement _attributes(String preambleXml) =>
    XmlDocument.parse(preambleXml).findAllElements('attributes').single;

void main() {
  test('carries the opening clef, key and time', () {
    final out = buildPreambleXml(_score('<attributes><divisions>2</divisions>'
        '<key><fifths>1</fifths></key>'
        '<time><beats>2</beats><beat-type>4</beat-type></time>'
        '<clef><sign>G</sign><line>2</line></clef></attributes>'));
    final a = _attributes(out);
    expect(a.findElements('key').single.innerText, contains('1'));
    expect(a.findElements('time').single.findElements('beats').single.innerText, '2');
    expect(a.findElements('clef').single.findElements('sign').single.innerText, 'G');
  });

  // An OMR scan writes divisions in one block and key/time/clef in a second;
  // reading only the first engraved a bare five-line staff in the title bar.
  test('merges a split opening <attributes> (scanned pieces)', () {
    final out = buildPreambleXml(_score(
        '<attributes><divisions>2</divisions></attributes>'
        '<attributes><key><fifths>1</fifths></key>'
        '<time><beats>4</beats><beat-type>4</beat-type></time>'
        '<clef><sign>G</sign><line>2</line></clef></attributes>'));
    final a = _attributes(out);
    expect(a.findElements('divisions').single.innerText, '2');
    expect(a.findElements('key'), hasLength(1));
    expect(a.findElements('time'), hasLength(1));
    expect(a.findElements('clef'), hasLength(1));
    // The invisible rest fills the bar from the merged divisions × beats.
    final rest = XmlDocument.parse(out).findAllElements('note').single;
    expect(rest.findElements('duration').single.innerText, '8');
  });

  test('a piece that changes meter has no time signature in the title bar', () {
    final out = buildPreambleXml(_score('<attributes><divisions>2</divisions>'
            '<key><fifths>1</fifths></key>'
            '<time><beats>4</beats><beat-type>4</beat-type></time>'
            '<clef><sign>G</sign><line>2</line></clef></attributes>')
        .replaceFirst('</measure>',
            '</measure><measure number="2"><attributes><time><beats>3</beats>'
                '<beat-type>4</beat-type></time></attributes></measure>'));
    final a = _attributes(out);
    expect(a.findElements('time'), isEmpty);
    expect(a.findElements('clef'), hasLength(1));
  });
}

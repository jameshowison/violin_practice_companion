import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/bar_rest_repair.dart';
import 'package:violin_practice_companion/services/meter_repair.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

const _note = '<note><pitch><step>D</step><octave>4</octave></pitch>'
    '<duration>2</duration><type>eighth</type></note>';

/// A whole rest as the recogniser writes it: a whole note's worth, 16
/// divisions at 4 to the quarter, with nothing saying it fills the bar.
const _wholeRest = '<note><rest/><duration>16</duration><type>whole</type></note>';

/// A 2/4 scan (divisions 4): bars of four eighths, except where [rests] says
/// a bar holds only a whole rest.
String _scan(int bars, Set<int> rests) {
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>'
      '<score-partwise version="4.0"><part-list><score-part id="P1">'
      '<part-name>Violin</part-name></score-part></part-list><part id="P1">');
  for (var n = 1; n <= bars; n++) {
    buf.write('<measure number="$n">');
    if (n == 1) {
      buf.write('<attributes><divisions>4</divisions><key><fifths>1</fifths>'
          '</key><time><beats>2</beats><beat-type>4</beat-type></time>'
          '<clef><sign>G</sign><line>2</line></clef></attributes>');
    }
    buf.write(rests.contains(n) ? _wholeRest : _note * 4);
    buf.write('</measure>');
  }
  buf.write('</part></score-partwise>');
  return buf.toString();
}

String _scanChain(String xml) =>
    BarRestRepair.fit(MeterRepair.repair(BarRestRepair.mark(xml)));

double _quarters(String xml) => MidiGenerator.forTest()
    .generate(MusicXmlParser().parse(xml), 60)
    .totalDurationSeconds;

void main() {
  test('a whole rest alone in a 2/4 bar lasts the bar, not four beats', () {
    // Three in a row, as at the end of a section, plus a lone one.
    final xml = _scan(8, {2, 5, 6, 7});
    expect(_quarters(xml), 24, reason: 'unrepaired: four beats per rest bar');

    final repaired = _scanChain(xml);
    expect(_quarters(repaired), 16);
    expect('measure="yes"'.allMatches(repaired), hasLength(4));
    expect(repaired, isNot(contains('<duration>16</duration>')));
  });

  test('three whole-rest bars in a row are no evidence for 4/4', () {
    // Unmarked, they were: MeterRepair saw three 4-beat bars and wrote a
    // change to 4/4 (and back) into a piece that never leaves 2/4.
    expect(MeterRepair.repair(_scan(8, {5, 6, 7})),
        contains('<beats>4</beats>'));
    final repaired = _scanChain(_scan(8, {5, 6, 7}));
    expect('<time>'.allMatches(repaired), hasLength(1));
    expect(repaired, isNot(contains('<beats>4</beats>')));
  });

  test('a whole rest that shares its bar is left alone', () {
    final xml = _scan(4, {}).replaceFirst(
        '<measure number="3">$_note$_note$_note$_note',
        '<measure number="3">$_note$_wholeRest');
    expect(BarRestRepair.mark(xml), xml);
  });

  test('a score with no whole rests comes back unchanged', () {
    final xml = _scan(4, {});
    expect(_scanChain(xml), xml);
  });
}

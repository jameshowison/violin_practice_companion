import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece_layout.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:score_view/score_view.dart';

/// Laying repeated sections out alike, on numbers measured from Happy Farmer:
/// the label rule in the line planner, and the opening pickup's hidden rest
/// that made the first A wider than its twins. Needs no restricted fixtures.
void main() {
  group('line planner', () {
    // Happy Farmer's natural widths on the SE: A A B C A, five slices each.
    const widths = <double>[
      129, 248, 270, 307, 221, // A 1175
      70, 248, 270, 307, 221, // A 1116
      70, 248, 285, 248, 233, // B 1084
      55, 307, 271, 248, 233, // C 1114
      70, 248, 270, 307, 257, // A 1152
    ];
    const starts = [0, 5, 10, 15, 20];
    const labels = {0: 'A', 5: 'A', 10: 'B', 15: 'C', 20: 'A'};
    // Every section on two lines, each cut after its third slice.
    const allTwo = {3, 8, 13, 18, 23};

    test('sections sharing a label take the same number of lines', () {
      // A line limit between the second A and the last: alone, the A's
      // come out two lines, one, two.
      final alone = planSectionLines(
          widths: widths,
          segmentStarts: starts,
          maxLineUnits: 1130,
          balanceDensity: false);
      expect(alone.breaks, {3, 23});
      // Every A on two lines; B and C, with no twin, unchanged.
      expect(
          planSectionLines(
            widths: widths,
            segmentStarts: starts,
            maxLineUnits: 1130,
            segmentLabels: labels,
            balanceDensity: false,
          ).breaks,
          {3, 8, 23});
      // A label inside a segment (a section whose line opens on the pickup)
      // labels that segment.
      expect(
          planSectionLines(
            widths: widths,
            segmentStarts: starts,
            maxLineUnits: 1130,
            segmentLabels: const {1: 'A', 5: 'A', 20: 'A'},
            balanceDensity: false,
          ).breaks,
          {3, 8, 23});
      // The user's own lines-per-section count wins over both rules.
      expect(
          planSectionLines(
            widths: widths,
            segmentStarts: starts,
            maxLineUnits: 1130,
            lines: 1,
            segmentLabels: labels,
          ).breaks,
          isEmpty);
    });

    test('B and C split to match the two-line A sections', () {
      // Lines of 528-647 beside 1084 and 1114 (a spread of 2.1): every
      // section on two lines brings it to 1.35. Splitting C alone would make
      // it worse (B becomes the widest), so this needs the common cap.
      final plan = planSectionLines(
          widths: widths,
          segmentStarts: starts,
          maxLineUnits: 1130,
          segmentLabels: labels);
      expect(plan.breaks, allTwo);
      expect(plan.widestUnits, 647);
      // Without labels too: the density rule alone gets there.
      expect(
          planSectionLines(
                  widths: widths, segmentStarts: starts, maxLineUnits: 1130)
              .breaks,
          allTwo);
    });

    test('all on one line is already even: nothing added', () {
      final plan = planSectionLines(
          widths: widths,
          segmentStarts: starts,
          maxLineUnits: 1200,
          segmentLabels: labels);
      expect(plan.breaks, isEmpty);
    });

    test('a long section splits to match a short one', () {
      // 16 bars and 8, room for 17 a line: one line each would draw the
      // 8-bar section twice as sparse. Two lines of 8 and one of 8 match.
      final bars = List<double>.filled(24, 100);
      expect(
          planSectionLines(
                  widths: bars, segmentStarts: const [0, 16], maxLineUnits: 1700)
              .breaks,
          {8});
    });

    test('a short coda does not make everything split to its size', () {
      // Two 8-bar sections and a 2-bar coda under half a line: the coda is
      // left sparse rather than cutting the rest into 3-bar lines.
      final bars = <double>[...List<double>.filled(16, 100), 150, 150];
      expect(
          planSectionLines(
                  widths: bars,
                  segmentStarts: const [0, 8, 16],
                  maxLineUnits: 900)
              .breaks,
          isEmpty);
    });

    test('a split that only shaves the spread a little is not taken', () {
      // 1000 and 900 on one line each: a spread of 1.11, already within
      // reach of anything a split could do.
      final bars = <double>[...List<double>.filled(10, 100), ...List<double>.filled(9, 100)];
      expect(
          planSectionLines(
                  widths: bars, segmentStarts: const [0, 10], maxLineUnits: 1100)
              .breaks,
          isEmpty);
    });
  });

  group('opening hidden rests', () {
    String piece(String firstMeasure) => '''<?xml version="1.0"?>
<score-partwise><part-list><score-part id="P1"/></part-list><part id="P1">
<measure number="0" implicit="yes"><attributes><divisions>2</divisions>
<time><beats>4</beats><beat-type>4</beat-type></time></attributes>
$firstMeasure</measure>
<measure number="1"><note print-object="no"><rest/><duration>8</duration><type>whole</type></note></measure>
</part></score-partwise>''';
    const hiddenRest =
        '<note print-object="no"><rest/><duration>1</duration><type>eighth</type></note>';
    const d4 =
        '<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><type>eighth</type></note>';

    test('the pickup loses its padding rest, the parsed piece keeps it', () {
      final xml = piece(hiddenRest + d4);
      final out = PieceLayout.dropOpeningHiddenRests(xml);
      final firstBar = out.substring(0, out.indexOf('<measure number="1"'));
      expect(firstBar, isNot(contains('print-object')));
      expect(firstBar, contains('<step>D</step>'));
      // A hidden rest in a later bar holds real time: left alone.
      expect(out.substring(out.indexOf('<measure number="1"')),
          contains('print-object="no"'));
      // Playback's timing comes from the parsed source, which still has it.
      expect(MusicXmlParser().parse(xml).measures.first.hiddenLeadNotes, hasLength(1));
    });

    test('a hidden rest after the first printed note stays', () {
      final xml = piece(d4 + hiddenRest);
      expect(PieceLayout.dropOpeningHiddenRests(xml), xml);
    });

    test('nothing to drop leaves the xml as it was', () {
      final xml = piece(d4 + d4);
      expect(PieceLayout.dropOpeningHiddenRests(xml), xml);
    });
  });
}

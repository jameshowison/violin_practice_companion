import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece_layout.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/section_line_planner.dart';

/// Laying repeated sections out alike, on numbers measured from Happy Farmer:
/// the label rule in the line planner, and the opening pickup's hidden rest
/// that made the first A wider than its twins. Needs no restricted fixtures.
void main() {
  group('line planner', () {
    test('sections sharing a label take the same number of lines', () {
      // Happy Farmer's natural widths on the SE: A A B C A, five slices each.
      final widths = <double>[
        129, 248, 270, 307, 221, // A 1175
        70, 248, 270, 307, 221, // A 1116
        70, 248, 285, 248, 233, // B 1084
        55, 307, 271, 248, 233, // C 1114
        70, 248, 270, 307, 257, // A 1152
      ];
      const starts = [0, 5, 10, 15, 20];
      // A line limit between the second A and the last: alone, the A's
      // come out two lines, one, two.
      final alone = planSectionLines(
          widths: widths, segmentStarts: starts, maxLineUnits: 1130);
      expect(alone.breaks, {3, 23});
      final labelled = planSectionLines(
        widths: widths,
        segmentStarts: starts,
        maxLineUnits: 1130,
        segmentLabels: const {0: 'A', 5: 'A', 10: 'B', 15: 'C', 20: 'A'},
      );
      // Every A on two lines, each cut after its third slice; B and C, with
      // no twin, unchanged.
      expect(labelled.breaks, {3, 8, 23});
      // A label inside a segment (a section whose line opens on the pickup)
      // labels that segment.
      expect(
          planSectionLines(
            widths: widths,
            segmentStarts: starts,
            maxLineUnits: 1130,
            segmentLabels: const {1: 'A', 5: 'A', 20: 'A'},
          ).breaks,
          {3, 8, 23});
      // The user's own lines-per-section count wins over the label rule.
      expect(
          planSectionLines(
            widths: widths,
            segmentStarts: starts,
            maxLineUnits: 1130,
            lines: 1,
            segmentLabels: const {0: 'A', 5: 'A', 20: 'A'},
          ).breaks,
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

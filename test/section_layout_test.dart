import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:violin_practice_companion/models/engraved_measure_map.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/section_detector.dart';
import 'package:violin_practice_companion/services/section_line_planner.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';
import 'package:violin_practice_companion/services/system_break_injector.dart';

/// Section-aware staff layout, end to end on Along the Road to Gundagai (2/4,
/// a one-beat opening pickup, four 8-bar strains each entered on a one-beat
/// lead-in at the end of the bar before): lead-in detection, the bar splits,
/// the engraved measure map, the section breaks and the line planner.
void main() {
  final xml = File('test/fixtures/gundagai_lyrics.musicxml').readAsStringSync();
  final measures = MusicXmlParser().parse(xml).measures;
  // The detector's bar-counted sections, on downbeats — what the dev
  // library's sidecar holds for this tune.
  const downbeat = [
    Section(label: 'A', startMeasure: 2),
    Section(label: 'B', startMeasure: 10),
    Section(label: 'C', startMeasure: 18),
    Section(label: 'D', startMeasure: 26),
  ];
  final sections = SectionDetector.withLeadIns(downbeat, measures);

  List<XmlElement> measuresOf(String s) =>
      XmlDocument.parse(s).findAllElements('measure').toList();
  bool breaksBefore(XmlElement m) => m
      .findElements('print')
      .any((p) => p.getAttribute('new-system') == 'yes');
  List<String> lyricsOf(XmlElement m) => [
        for (final t in m.findAllElements('text')) t.innerText,
      ];

  group('lead-ins', () {
    test('each later strain starts on the last beat of the bar before', () {
      expect(sections, const [
        Section(label: 'A', startMeasure: 2),
        Section(label: 'B', startMeasure: 9, startNote: 1), // "Where the"
        Section(label: 'C', startMeasure: 17, startNote: 2), // past the rest
        Section(label: 'D', startMeasure: 25, startNote: 1), // "No more"
      ]);
    });

    test('a piece with no opening pickup gets none', () {
      expect(SectionDetector.withLeadIns(downbeat, measures.sublist(1)),
          downbeat);
    });

    test('detect() finds them on import', () {
      expect(SectionDetector.detect(measures).map((s) => s.startNote),
          [0, 1, 2, 1]);
    });
  });

  group('bar splits', () {
    final splits = sectionBarSplits(sections, measures);
    final split = splitBarsAtSections(xml, splits);
    final ms = measuresOf(split);

    test('cut each lead-in bar where its section starts', () {
      expect(splits, [
        (measure: 9, note: 1),
        (measure: 17, note: 2),
        (measure: 25, note: 1),
      ]);
      expect(ms.length, measures.length + 3);
      expect([for (final m in ms) m.getAttribute('number')].sublist(7, 11),
          ['8', '9', '9b', '10']);
    });

    test('the words go with their notes', () {
      final m9 = ms.firstWhere((m) => m.getAttribute('number') == '9');
      final m9b = ms.firstWhere((m) => m.getAttribute('number') == '9b');
      expect(lyricsOf(m9), isEmpty); // the held "gai"
      expect(lyricsOf(m9b), ['Where', 'the']);
      expect(m9b.getAttribute('implicit'), 'yes');
    });

    test('the first half ends with no barline; the beam restarts', () {
      final m9 = ms.firstWhere((m) => m.getAttribute('number') == '9');
      final m9b = ms.firstWhere((m) => m.getAttribute('number') == '9b');
      expect(m9.findAllElements('bar-style').single.innerText, 'none');
      expect(m9b.findAllElements('beam').map((b) => b.innerText),
          ['begin', 'end']);
    });

    test('the halves add up to the bar', () {
      int dur(XmlElement m) => m
          .findElements('note')
          .fold(0, (s, n) => s + int.parse(n.getElement('duration')!.innerText));
      for (final n in ['9', '17', '25']) {
        final a = ms.firstWhere((m) => m.getAttribute('number') == n);
        final b = ms.firstWhere((m) => m.getAttribute('number') == '${n}b');
        expect(dur(a) + dur(b), 192, reason: 'bar $n');
      }
    });

    test('a harmony just before the cut note moves with it', () {
      final src = '<score-partwise><part id="P1"><measure number="1">'
          '<note><duration>1</duration></note>'
          '<harmony><root><root-step>G</root-step></root></harmony>'
          '<note><duration>1</duration></note>'
          '<barline location="right"><repeat direction="backward"/></barline>'
          '</measure><measure number="2"><note><duration>2</duration></note>'
          '</measure></part></score-partwise>';
      final out = measuresOf(
          splitBarsAtSections(src, const [(measure: 1, note: 1)]));
      expect(out.map((m) => m.getAttribute('number')), ['1', '1b', '2']);
      expect(out[1].findElements('harmony'), hasLength(1));
      expect(out[0].findElements('harmony'), isEmpty);
      // The repeat stays on the bar's real end, the second slice.
      expect(out[1].findAllElements('repeat'), hasLength(1));
      expect(out[0].findAllElements('repeat'), isEmpty);
    });
  });

  group('section breaks', () {
    final split =
        splitBarsAtSections(xml, sectionBarSplits(sections, measures));

    test('every section opens a line, its lead-in first', () {
      final out = insertSystemBreaks(split, sections: sections);
      expect([
        for (final m in measuresOf(out))
          if (breaksBefore(m)) m.getAttribute('number'),
      ], ['9b', '17b', '25b']);
    });

    test('the opening pickup is never left alone on a line', () {
      // Downbeat sections, unsplit: A starts at m2 right after the pickup.
      final out = insertSystemBreaks(xml, sections: downbeat);
      final broken = [
        for (final m in measuresOf(out))
          if (breaksBefore(m)) m.getAttribute('number'),
      ];
      expect(broken, ['10', '18', '26']);
    });

    test('locked: the budget counts within a section, not the halves', () {
      final out =
          insertSystemBreaks(split, measuresPerLine: 4, sections: sections);
      expect([
        for (final m in measuresOf(out))
          if (breaksBefore(m)) m.getAttribute('number'),
      ], ['6', '9b', '14', '17b', '22', '25b', '30']);
    });

    test('breaks at engraved positions land on the slices', () {
      final starts = systemStartPositions(
          insertSystemBreaks(split, sections: sections));
      expect(starts, [0, 9, 18, 27]); // m1, m9b, m17b, m25b
      final out = insertBreaksAtPositions(split, {4});
      expect(measuresOf(out).where(breaksBefore).single.getAttribute('number'),
          '5');
    });
  });

  group('engraved measure map', () {
    final map = EngravedMeasureMap.withSplits(
        measures, sectionBarSplits(sections, measures));

    test('a split bar is two slices of one measure', () {
      expect(map.length, measures.length + 3);
      expect(map.firstIndexOf(9), 8);
      expect(map.lastIndexOf(9), 9);
      expect(map.firstIndexOf(10), 10);
      expect(map.indicesOf(9).toList(), [8, 9]);
      expect(map.hasSplits, isTrue);
    });

    test('model notes land in the slice that engraves them', () {
      expect(map.locate(9, 0), (index: 8, note: 0)); // "gai" held
      expect(map.locate(9, 1), (index: 9, note: 0)); // "Where"
      expect(map.locate(9, 2), (index: 9, note: 1)); // "the"
      expect(map.locate(10, 0), (index: 10, note: 0));
      expect(map.locate(99, 0), isNull);
    });

    test('section ranges end on the cut, not across it', () {
      final ranges = resolveSectionRanges(sections, measures);
      final a = ranges.first;
      expect(map.range(a.startMeasure, a.startNote, a.endMeasure, a.endNote), (
        startMeasureIndex: 1,
        startNote: 0,
        endMeasureIndex: 8, // m9's first slice, whole
        endNote: -1,
      ));
      final b = ranges[1];
      expect(map.range(b.startMeasure, b.startNote, b.endMeasure, b.endNote), (
        startMeasureIndex: 9, // m9b
        startNote: 0,
        endMeasureIndex: 17, // m17's first slice, whole
        endNote: -1,
      ));
    });

    test('identity behaves like the plain number list', () {
      final id = EngravedMeasureMap.identity(const [0, 1, 2]);
      expect(id.firstIndexOf(1), 1);
      expect(id.lastIndexOf(1), 1);
      expect(id.locate(2, 3), (index: 2, note: 3));
      expect(id.range(0, 1, 2, 2),
          (startMeasureIndex: 0, startNote: 1, endMeasureIndex: 2, endNote: 2));
      expect(id.hasSplits, isFalse);
    });

    test('splits skip the first bar, the bar end, and downbeats', () {
      final ms = <Measure>[
        for (var n = 1; n <= 3; n++) measures[n],
      ];
      expect(
          sectionBarSplits([
            Section(label: 'A', startMeasure: ms[0].number, startNote: 1),
            Section(label: 'B', startMeasure: ms[1].number),
            Section(label: 'C', startMeasure: ms[2].number, startNote: 99),
          ], ms),
          isEmpty);
    });
  });

  group('line planner', () {
    test('fewest lines that fit, balanced by width', () {
      // Two 8-bar sections of 100-unit bars: 800 a line won't fit in 500.
      final widths = List<double>.filled(16, 100);
      final plan = planSectionLines(
          widths: widths, segmentStarts: const [0, 8], maxLineUnits: 500);
      expect(plan.breaks, {4, 12});
      expect(plan.widestUnits, 400);
      // And one line each when they fit.
      final roomy = planSectionLines(
          widths: widths, segmentStarts: const [0, 8], maxLineUnits: 900);
      expect(roomy.breaks, isEmpty);
      expect(roomy.widestUnits, 800);
    });

    test('a wide lead-in pushes a bar onto the second line', () {
      // Lead-in half bar, 8 bars, closing half bar — the shape of a Gundagai
      // section — with a wordy first bar.
      final seg = <double>[160, 100, 100, 100, 100, 100, 100, 100, 100, 50];
      final plan = balancedLines(seg, 2);
      // Bar-count halves: 160+400 = 560 | 400+50 = 450. One bar later:
      // 460 | 550 — a narrower widest line, so the planner takes it.
      expect(plan.breaks, [4]);
      expect(plan.widest, 550);
    });

    test('a set line count overrides the fit, and is reported', () {
      final widths = List<double>.filled(16, 100);
      // Room for a whole section a line, but the user asked for two.
      final plan = planSectionLines(
          widths: widths,
          segmentStarts: const [0, 8],
          maxLineUnits: 900,
          lines: 2);
      expect(plan.breaks, {4, 12});
      expect(plan.maxLines, 2);
      // A three-bar section can't take four lines: one bar each.
      final short = planSectionLines(
          widths: List<double>.filled(3, 100),
          segmentStarts: const [0],
          maxLineUnits: 900,
          lines: 4);
      expect(short.breaks, {1, 2});
      expect(short.maxLines, 3);
      // Auto reports the most lines any section needed.
      expect(
          planSectionLines(
                  widths: widths, segmentStarts: const [0, 8], maxLineUnits: 500)
              .maxLines,
          2);
    });

    test('pinching out asks for more lines per section', () {
      expect(pinchTargetLinesPerSection(from: 1, scale: 2), 2);
      expect(pinchTargetLinesPerSection(from: 2, scale: 0.5), 1);
      expect(pinchTargetLinesPerSection(from: 2, scale: 10), linesPerSectionMax);
      expect(pinchScaleLimitsForLines(1), (min: 1.0, max: 4.0));
      expect(pinchScaleLimitsForLines(2), (min: 0.5, max: 2.0));
    });

    test('ties go to the lighter first line', () {
      final plan = balancedLines([50.0, 100, 100, 100, 100, 50], 2);
      // 250 | 250, the one exact balance.
      expect(plan.breaks, [3]);
      expect(balancedLines([100.0, 100, 100], 2).breaks, [1]); // 100 | 200
    });
  });
}

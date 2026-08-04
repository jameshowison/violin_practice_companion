import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';
import 'package:violin_practice_companion/services/verovio_engraver.dart';

/// An engraved score with [lines] systems, each [inkHeight] tall, separated by
/// [gap] of whitespace, with [topMargin] above the first. Only the fields the
/// lane maths reads are populated.
EngravedScore _score({
  int lines = 3,
  double inkHeight = 60,
  double gap = 21,
  double topMargin = 32,
  int laneCount = 1,
}) {
  final content = <({double top, double bottom})>[];
  var y = topMargin;
  for (var l = 0; l < lines; l++) {
    content.add((top: y, bottom: y + inkHeight));
    y += inkHeight + gap;
  }
  return EngravedScore(
    viewBox: Size(400, y),
    svg: '',
    bboxById: const {},
    measures: const [],
    notes: const [],
    measureLine: [for (var l = 0; l < lines; l++) l],
    lineBands: content,
    lineContent: content,
    pageWidthUnits: 1000,
    renderMs: 0,
    laneCount: laneCount,
  );
}

void main() {
  group('lane reservation', () {
    test('one lane is free — a staff-view engrave is unchanged', () {
      expect(verovioLaneSpacingUnits(1), 0);
      expect(verovioLaneMarginUnits(1), 0);
    });

    test('each lane past the first costs one lane of room in both knobs', () {
      expect(verovioLaneSpacingUnits(2), laneReserveSpacingUnitsPerLane);
      expect(verovioLaneMarginUnits(2), laneReserveMarginUnitsPerLane);
      expect(verovioLaneSpacingUnits(3), 2 * laneReserveSpacingUnitsPerLane);
      expect(verovioLaneMarginUnits(3), 2 * laneReserveMarginUnitsPerLane);
    });

    test('the two knobs are calibrated separately, not shared', () {
      // A margin unit buys ~9× less room than a spacing unit, so equal counts
      // would over-reserve the gap enough to change the whole-piece layout.
      expect(laneReserveMarginUnitsPerLane,
          greaterThan(laneReserveSpacingUnitsPerLane));
    });

    test('a nonsensical count clamps rather than throwing', () {
      for (final f in [verovioLaneSpacingUnits, verovioLaneMarginUnits]) {
        expect(f(0), 0);
        expect(f(-3), 0);
        expect(f(50), 4 * f(2));
      }
    });
  });

  group('annotationLaneBand', () {
    test('a 1-lane score puts the chord lane in slot 0, as it always was', () {
      final s = _score(laneCount: 1);
      expect(s.chordLaneBand(0), s.annotationLaneBand(0, 0));
      // And nothing is reserved for a channel, so asking for one gets nothing.
      expect(s.fingeringLaneBand(0), isNull);
      expect(s.annotationLaneBand(0, 1), isNull);
    });

    test('the lane sits in the whitespace, clear of the ink', () {
      final s = _score(laneCount: 1);
      final band = s.chordLaneBand(1)!;
      expect(band.bottom, lessThan(s.lineContent[1].top),
          reason: 'the lane must clear the ink it sits above');
      expect(band.top, greaterThan(s.lineContent[0].bottom),
          reason: 'and must not reach back into the previous system');
    });

    test('two lanes stack: slot 0 below slot 1, neither overlapping', () {
      // Enough gap that both lanes get their full proportional height.
      final s = _score(gap: 60, topMargin: 60, laneCount: 2);
      expect(s.laneSqueeze, 1.0, reason: 'this score has room for both lanes');
      final finger = s.annotationLaneBand(2, 0)!;
      final chord = s.annotationLaneBand(2, 1)!;
      expect(finger.bottom, greaterThan(chord.bottom),
          reason: 'slot 0 is the lower lane — nearer the notes');
      expect(chord.bottom, moreOrLessEquals(finger.top),
          reason: 'the lanes must touch exactly, with no gap or overlap');
    });

    test('the channel is shorter than the chord lane, at its own fraction', () {
      final s = _score(gap: 60, topMargin: 60, laneCount: 2);
      final yard = s.contentHeightViewBox;
      expect(s.annotationLaneHeight(0),
          moreOrLessEquals(yard * EngravedScore.fingeringLaneHeightFraction));
      expect(s.annotationLaneHeight(1),
          moreOrLessEquals(yard * EngravedScore.chordLaneHeightFraction));
      expect(s.annotationLaneHeight(0), lessThan(s.annotationLaneHeight(1)),
          reason: 'a "2L" chip needs less height than an "IV (G)" bar, and the '
              'saving is what keeps the gap reservation affordable');
    });

    test('adding a channel does not change the chord lane height', () {
      // The whole point of buying room rather than subdividing it.
      final one = _score(gap: 60, topMargin: 60, laneCount: 1);
      final two = _score(gap: 60, topMargin: 60, laneCount: 2);
      expect(two.annotationLaneHeight(1),
          moreOrLessEquals(one.annotationLaneHeight(0)));
    });

    test('the chord lane is always the top slot, so a channel cannot move it',
        () {
      final s = _score(gap: 60, topMargin: 60, laneCount: 2);
      expect(s.chordLaneBand(0), s.annotationLaneBand(0, 1));
      expect(s.fingeringLaneBand(0), s.annotationLaneBand(0, 0));
    });

    test('lane height is uniform across systems, not per-gap', () {
      // A score whose gaps differ would otherwise give each line its own height.
      final content = <({double top, double bottom})>[
        (top: 40, bottom: 100),
        (top: 130, bottom: 190), // 30 of gap
        (top: 260, bottom: 320), // 70 of gap
      ];
      final s = EngravedScore(
        viewBox: const Size(400, 400),
        svg: '',
        bboxById: const {},
        measures: const [],
        notes: const [],
        measureLine: const [0, 1, 2],
        lineBands: content,
        lineContent: content,
        pageWidthUnits: 1000,
        renderMs: 0,
      );
      final heights = [
        for (var l = 0; l < 3; l++)
          s.chordLaneBand(l)!.bottom - s.chordLaneBand(l)!.top
      ];
      expect(heights[0], moreOrLessEquals(heights[1]));
      expect(heights[1], moreOrLessEquals(heights[2]));
      // And it's the TIGHTEST gap that sets it, so no lane overflows its space.
      expect(heights[0], lessThan(30));
    });

    test('a score with no room reports none, rather than drawing over the ink',
        () {
      final s = _score(gap: 0, topMargin: 0, laneCount: 2);
      expect(s.laneSqueeze, 0);
      expect(s.annotationLaneHeight(0), 0);
      expect(s.chordLaneBand(0), isNull);
      expect(s.fingeringLaneBand(0), isNull);
    });

    test('a second lane in unreserved whitespace squeezes both, proportionally',
        () {
      // The degradation path when the reservation does not land: thinner lanes,
      // never lanes over the notes. Both shrink by the same factor, so the
      // channel stays the shorter of the two.
      // This fixture's whitespace is the pre-change default, which is already a
      // hair tight for even one lane — the real score measures a 0.94 squeeze on
      // the chord lane alone, and has since the lane shipped.
      final one = _score(laneCount: 1);
      final two = _score(laneCount: 2);
      expect(two.laneSqueeze, lessThan(one.laneSqueeze));
      expect(two.laneSqueeze, lessThan(1.0));
      expect(two.laneSqueeze, greaterThan(0));
      expect(two.annotationLaneHeight(1), lessThan(one.annotationLaneHeight(0)));
      expect(two.annotationLaneHeight(0), lessThan(two.annotationLaneHeight(1)));
    });

    test('out-of-range lines and slots return null', () {
      final s = _score(laneCount: 2);
      expect(s.chordLaneBand(-1), isNull);
      expect(s.chordLaneBand(99), isNull);
      expect(s.annotationLaneBand(0, -1), isNull);
      expect(s.annotationLaneBand(0, 2), isNull);
    });
  });
}

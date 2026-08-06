import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/violin_string_palette.dart';
// For the staffSpacing slider bounds — the floor has to hold across the whole
// range the user can actually drag to, not just the values we picked.
import 'package:violin_practice_companion/services/providers.dart';
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
  bool chordLane = true,
  bool fingeringLane = false,
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
    chordLane: chordLane,
    fingeringLane: fingeringLane,
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

  group('the reserve is a floor, not a bonus', () {
    // The regression this group exists for: the staff-spacing slider used to
    // change the annotation font size. The reserve was ADDED to the preference,
    // so any spacing under Verovio's own default ate back into it, `laneSqueeze`
    // fell under 1, and every label in the lane shrank with it — by about a third
    // at the bottom of the slider. Label size must track the notes and nothing
    // else, so the engraved gap has to stop falling once the lanes are full.

    test('a tight preference cannot engrave below what the lanes need', () {
      for (final lanes in [1, 2, 3]) {
        final floor = verovioSpacingSystemFloor(lanes);
        expect(verovioSpacingSystemEngraved(staffSpacingMin, lanes), floor,
            reason: 'the slider minimum must still leave lane room');
        expect(verovioSpacingSystemEngraved(0.3, lanes), floor);
        // Everything from the minimum up to the default lands on the floor, so
        // the bottom of the slider is a no-op — deliberately: with lanes
        // reserved there is no unused gap left to reclaim.
        expect(verovioSpacingSystemEngraved(staffSpacingDefault, lanes), floor);
      }
    });

    test('the default renders exactly as it did before the floor', () {
      // The floor is anchored on Verovio's own default, so wiring it up must not
      // move a score that nobody has touched the slider on.
      for (final lanes in [1, 2, 3]) {
        expect(
          verovioSpacingSystemEngraved(staffSpacingDefault, lanes),
          verovioSpacingSystemFor(staffSpacingDefault) +
              verovioLaneSpacingUnits(lanes),
        );
      }
    });

    test('above the default the preference still has its full reach', () {
      for (final lanes in [0, 1, 2]) {
        for (final s in [0.7, 1.0, staffSpacingMax]) {
          expect(
            verovioSpacingSystemEngraved(s, lanes),
            verovioSpacingSystemFor(s) + verovioLaneSpacingUnits(lanes),
            reason: 'the floor must not clip the airy half of the slider',
          );
        }
      }
      expect(verovioSpacingSystemEngraved(staffSpacingMax, 2),
          greaterThan(verovioSpacingSystemEngraved(staffSpacingDefault, 2)));
    });

    test('reserving nothing floors nothing — the slider keeps full reach', () {
      // A view drawing no annotation has no lane to protect, and the whitespace
      // it would have reserved is exactly what the preference should be able to
      // close up. This is what a staff view with the chords toggled off gets.
      expect(verovioSpacingSystemFloor(0), 0);
      for (final s in [staffSpacingMin, 0.3, staffSpacingDefault, 1.0]) {
        expect(verovioSpacingSystemEngraved(s, 0), verovioSpacingSystemFor(s));
      }
      expect(verovioSpacingSystemEngraved(staffSpacingMin, 0), 0);
    });

    test('the engraved gap is monotonic in the preference', () {
      for (final lanes in [0, 1, 2]) {
        var prev = -1;
        for (var s = staffSpacingMin; s <= staffSpacingMax; s += 0.05) {
          final units = verovioSpacingSystemEngraved(s, lanes);
          expect(units, greaterThanOrEqualTo(prev),
              reason: 'dragging the slider up must never tighten the gap');
          prev = units;
        }
      }
    });

    test('a gap engraved at the floor leaves the lanes unsqueezed', () {
      // The floor's whole job, stated in the units the painter cares about: at
      // the floor `laneSqueeze` is 1, so the labels are full size. Expressed as
      // the fractions of contentHeight the reserve was calibrated against —
      // 0.30 per lane plus a clearance pad above and below.
      const yard = 60.0; // inkHeight, so contentHeightViewBox == 60
      const pad = yard * EngravedScore.annotationLanePadFraction;
      for (final lanes in [1, 2]) {
        final need = yard * EngravedScore.chordLaneHeightFraction * lanes;
        final s = _score(
          inkHeight: yard,
          gap: need + 2 * pad,
          topMargin: need + pad,
          fingeringLane: lanes >= 2,
        );
        expect(s.laneSqueeze, moreOrLessEquals(1.0),
            reason: '$lanes lane(s) at their calibrated room must not squeeze');
      }
    });
  });

  group('annotationLaneBand', () {
    test('a 1-lane score puts the chord lane in slot 0, as it always was', () {
      final s = _score();
      expect(s.chordLaneBand(0), s.annotationLaneBand(0, 0));
      // And nothing is reserved for a channel, so asking for one gets nothing.
      expect(s.fingeringLaneBand(0), isNull);
      expect(s.annotationLaneBand(0, 1), isNull);
    });

    test('the lane sits in the whitespace, clear of the ink', () {
      final s = _score();
      final band = s.chordLaneBand(1)!;
      expect(band.bottom, lessThan(s.lineContent[1].top),
          reason: 'the lane must clear the ink it sits above');
      expect(band.top, greaterThan(s.lineContent[0].bottom),
          reason: 'and must not reach back into the previous system');
    });

    test('two lanes stack: slot 0 below slot 1, neither overlapping', () {
      // Enough gap that both lanes get their full proportional height.
      final s = _score(gap: 60, topMargin: 60, fingeringLane: true);
      expect(s.laneSqueeze, 1.0, reason: 'this score has room for both lanes');
      final finger = s.annotationLaneBand(2, 0)!;
      final chord = s.annotationLaneBand(2, 1)!;
      expect(finger.bottom, greaterThan(chord.bottom),
          reason: 'slot 0 is the lower lane — nearer the notes');
      expect(chord.bottom, moreOrLessEquals(finger.top),
          reason: 'the lanes must touch exactly, with no gap or overlap');
    });

    test('each lane gets its own fraction of the content height', () {
      final s = _score(gap: 60, topMargin: 60, fingeringLane: true);
      final yard = s.contentHeightViewBox;
      expect(s.annotationLaneHeight(0),
          moreOrLessEquals(yard * EngravedScore.fingeringLaneHeightFraction));
      expect(s.annotationLaneHeight(1),
          moreOrLessEquals(yard * EngravedScore.chordLaneHeightFraction));
    });

    test('the chips still draw in the shorter zone the channel used to be', () {
      // The channel is full chord-lane height because the underline style stacks
      // a number over a rule and staggers both across four string levels. The
      // chip styles kept the old height, so growing the channel didn't silently
      // grow the chips — see `_FingeringLanePainter._chipZone`.
      expect(EngravedScore.fingeringChipZoneFraction,
          lessThan(EngravedScore.fingeringLaneHeightFraction));
      final s = _score(gap: 60, topMargin: 60, fingeringLane: true);
      final yard = s.contentHeightViewBox;
      final zone = s.annotationLaneHeight(0) *
          (EngravedScore.fingeringChipZoneFraction /
              EngravedScore.fingeringLaneHeightFraction);
      expect(zone,
          moreOrLessEquals(yard * EngravedScore.fingeringChipZoneFraction));
      expect(zone, lessThan(s.annotationLaneHeight(1)),
          reason: 'a "2L" chip needs less height than an "IV (G)" bar');
    });

    test('adding a channel does not change the chord lane height', () {
      // The whole point of buying room rather than subdividing it.
      final one = _score(gap: 60, topMargin: 60);
      final two = _score(gap: 60, topMargin: 60, fingeringLane: true);
      expect(two.annotationLaneHeight(1),
          moreOrLessEquals(one.annotationLaneHeight(0)));
    });

    test('the chord lane is always the top slot, so a channel cannot move it',
        () {
      final s = _score(gap: 60, topMargin: 60, fingeringLane: true);
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
      final s = _score(gap: 0, topMargin: 0, fingeringLane: true);
      expect(s.laneSqueeze, 0);
      expect(s.annotationLaneHeight(0), 0);
      expect(s.chordLaneBand(0), isNull);
      expect(s.fingeringLaneBand(0), isNull);
    });

    test('a second lane in unreserved whitespace squeezes both, proportionally',
        () {
      // The degradation path when the reservation does not land: thinner lanes,
      // never lanes over the notes. Both shrink by the same factor, so their
      // proportions to each other hold.
      // This fixture's whitespace is the pre-change default, which is already a
      // hair tight for even one lane — the real score measures a 0.94 squeeze on
      // the chord lane alone, and has since the lane shipped.
      final one = _score();
      final two = _score(fingeringLane: true);
      expect(two.laneSqueeze, lessThan(one.laneSqueeze));
      expect(two.laneSqueeze, lessThan(1.0));
      expect(two.laneSqueeze, greaterThan(0));
      expect(two.annotationLaneHeight(1), lessThan(one.annotationLaneHeight(0)));
      expect(two.annotationLaneHeight(0),
          moreOrLessEquals(two.annotationLaneHeight(1)),
          reason: 'the two lanes shrink by the same factor');
    });

    test('the channel is tall enough for the underline stagger', () {
      // The budget the painter divides up: a number, the gap under it, the rule,
      // and one step per string above G. If the channel were only the chip zone
      // the top string's rule would climb out of the band and into the chord
      // lane, so this is the constraint that set `fingeringLaneHeightFraction`.
      final needed = underlineRuleFraction +
          underlineRuleGapFraction +
          ViolinStringPalette.maxStackOrder * underlineStringStepFraction;
      expect(needed + underlineTextFraction, moreOrLessEquals(1.0),
          reason: 'the four parts divide the channel exactly, no overflow');
      expect(underlineTextFraction, greaterThan(0));
      // And the digits must still be at least the size they were before the
      // stagger, when they had the whole (shorter) channel bar rule and gap.
      final digitsNow =
          underlineTextFraction * EngravedScore.fingeringLaneHeightFraction;
      const digitsBefore =
          (1.0 - 0.20 - 0.08) * EngravedScore.fingeringChipZoneFraction;
      expect(digitsNow, greaterThanOrEqualTo(digitsBefore),
          reason: 'the stagger must not be paid for out of legibility');
      // A step you can't see isn't a cue; one as thick as the rule is a staircase.
      expect(underlineStringStepFraction, greaterThan(0.02));
      expect(underlineStringStepFraction, lessThan(underlineRuleFraction));
    });

    test('the strings stagger in pitch order, G on the floor', () {
      expect(ViolinStringPalette.stepOf('G'), 0);
      expect(ViolinStringPalette.stepOf('D'), 1);
      expect(ViolinStringPalette.stepOf('A'), 2);
      expect(ViolinStringPalette.stepOf('E'), 3);
      expect(ViolinStringPalette.maxStackOrder, 3);
      // An unknown string shares the floor rather than floating mid-stack, where
      // it would read as a string that doesn't exist.
      expect(ViolinStringPalette.stepOf(null), 0);
      expect(ViolinStringPalette.stepOf('B'), 0);
    });

    test('reserving nothing draws nothing, at any spacing', () {
      // The staff view with chords off. No lane means no band to draw into, and
      // (see the floor group) no floor under the gap either.
      final s = _score(gap: 60, topMargin: 60, chordLane: false);
      expect(s.laneCount, 0);
      expect(s.chordLaneBand(0), isNull);
      expect(s.fingeringLaneBand(0), isNull);
      expect(s.annotationLaneBand(0, 0), isNull);
    });

    test('a fingering-only score keeps its channel in slot 0', () {
      // The annotation view with chords toggled off: the channel must stay put
      // rather than inheriting the chord lane's slot, and it takes the room a
      // lone chord lane would have — the two are geometrically identical.
      final only = _score(gap: 60, topMargin: 60, chordLane: false, fingeringLane: true);
      final chords = _score(gap: 60, topMargin: 60);
      expect(only.laneCount, 1);
      expect(only.chordLaneBand(0), isNull);
      expect(only.fingeringLaneBand(0), only.annotationLaneBand(0, 0));
      expect(only.fingeringLaneBand(1), chords.chordLaneBand(1),
          reason: 'one lane is one lane, whatever is drawn in it');
    });

    test('dropping the chord lane gives the channel back its full height', () {
      // Why reserving only what is visible is worth a reflow: the second lane's
      // room comes out of the same whitespace, so not asking for it leaves more.
      final both = _score(fingeringLane: true);
      final only = _score(chordLane: false, fingeringLane: true);
      expect(both.laneSqueeze, lessThan(only.laneSqueeze));
      expect(only.annotationLaneHeight(0),
          greaterThan(both.annotationLaneHeight(0)));
    });

    test('out-of-range lines and slots return null', () {
      final s = _score(fingeringLane: true);
      expect(s.chordLaneBand(-1), isNull);
      expect(s.chordLaneBand(99), isNull);
      expect(s.annotationLaneBand(0, -1), isNull);
      expect(s.annotationLaneBand(0, 2), isNull);
    });
  });
}

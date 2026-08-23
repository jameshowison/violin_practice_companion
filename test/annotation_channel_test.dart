import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/violin_string_palette.dart';
// For the staffSpacing slider bounds — the stack has to hold across the whole
// range the user can actually drag to, not just the values we picked.
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';
import 'package:violin_practice_companion/widgets/chord_swatch.dart';

/// The annotation stack: how tall the chord bar and the fingering row are.
///
/// Replaces the old lane-reservation suite. That tested a reserve asked of
/// Verovio in MEI units, a lane height taken as a fraction of the system's ink
/// extent, and a `laneSqueeze` that scaled every lane in the score by its
/// tightest gap. None of those exist — the annotations are engraved, so Verovio
/// reserves their space itself and the app reads back the baselines it chose.
///
/// What is left to pin down is the SHARING, and it has bitten twice now:
///
/// * sizing each row to what it wanted made the fingering channel grow up past
///   the chord register and the bar paint straight over the digits;
/// * then making the bar absorb the whole shortfall per system gave bar heights
///   of 23.0, 5.3, 9.3, 9.3 and 22.2px down one page — present at the top and
///   bottom of the score, apparently missing in the middle.
///
/// So the properties that matter are: ONE size for the whole score, and both rows
/// shrinking together when the room is short.
void main() {
  // A staff space at the engraver's probe scale: staffHeightUnits × 40 / 100 / 4.
  const space = 7.2;
  final typeShare = underlineTextFraction;

  ({double barHeight, double channelHeight, double gap}) stack(
    double budgetPx, {
    double staffSpacePx = space,
  }) =>
      annotationStackFor(
        budgetPx: budgetPx,
        staffSpacePx: staffSpacePx,
        labelShare: chordLabelSizeFraction,
        typeShare: typeShare,
      );

  /// What the two rows want between them when nothing is in the way.
  double wanted([double staffSpacePx = space]) {
    final s = stack(double.infinity, staffSpacePx: staffSpacePx);
    return s.barHeight + s.channelHeight + s.gap;
  }

  group('when there is room', () {
    test('the fingering channel holds full-size type in the tallest style', () {
      final s = stack(double.infinity);
      expect(s.channelHeight * typeShare,
          closeTo(annotationFontSizeFor(space), 1e-9));
    });

    test('the chord bar holds full-size type too', () {
      final s = stack(double.infinity);
      expect(s.barHeight * chordLabelSizeFraction,
          closeTo(annotationFontSizeFor(space), 1e-9));
    });

    test('a budget at or above what is wanted changes nothing', () {
      final want = wanted();
      expect(stack(want).barHeight, closeTo(stack(double.infinity).barHeight, 1e-9));
      expect(stack(want * 4).channelHeight,
          closeTo(stack(double.infinity).channelHeight, 1e-9));
    });

    test('is scale-invariant — the rows hold their size against the notes', () {
      final small = stack(double.infinity);
      final big = stack(double.infinity, staffSpacePx: space * 3);
      expect(big.barHeight / small.barHeight, closeTo(3.0, 1e-9));
      expect(big.channelHeight / small.channelHeight, closeTo(3.0, 1e-9));
    });
  });

  group('when the room is short', () {
    // Measured on Old Joe Clark BEFORE the engrave asked for the room: 3.67 staff
    // spaces at the tightest system against the 6.03 the two rows want. That used
    // to be the normal case; with `annotationRoomSpaces` reserved it is the edge
    // one, reachable through the bottom of the staff-spacing slider or a score
    // tighter than any in `assets/fixtures`.
    final tight = space * 3.67;

    test('both rows shrink, in proportion — neither pays for the other', () {
      final full = stack(double.infinity);
      final s = stack(tight);
      expect(s.barHeight, lessThan(full.barHeight));
      expect(s.channelHeight, lessThan(full.channelHeight));
      expect(s.barHeight / s.channelHeight,
          closeTo(full.barHeight / full.channelHeight, 1e-9),
          reason: 'the split must stay proportional');
    });

    test('the stack fits the budget it was given', () {
      final s = stack(tight);
      expect(s.barHeight + s.channelHeight + s.gap,
          lessThanOrEqualTo(tight + 1e-9));
    });

    test('a floor keeps the rows legible rather than letting them vanish', () {
      final full = stack(double.infinity);
      final crushed = stack(space * 0.1);
      expect(crushed.channelHeight / full.channelHeight, greaterThan(0.5),
          reason: 'past the floor, small beats invisible');
      expect(crushed.barHeight, greaterThan(0));
    });

    test('degenerate inputs yield nothing, not a negative height', () {
      expect(stack(double.infinity, staffSpacePx: 0).barHeight, 0);
      expect(
        annotationStackFor(
          budgetPx: 100,
          staffSpacePx: space,
          labelShare: 0,
          typeShare: typeShare,
        ).barHeight,
        0,
      );
    });
  });

  // The property both bugs violated.
  group('uniformity', () {
    test('one budget gives one answer, whatever system asks', () {
      final budgets = [space * 3.67, space * 4.06, space * 5.39];
      // The score-wide minimum is what the caller passes, so every system gets
      // the SAME stack — that is what makes the row read as a register.
      final answers = budgets
          .map((_) => stack(budgets.reduce((a, b) => a < b ? a : b)))
          .map((s) => '${s.barHeight}|${s.channelHeight}')
          .toSet();
      expect(answers, hasLength(1));
    });

    test('the gap between the rows scales with them', () {
      final full = stack(double.infinity);
      final s = stack(space * 3.67);
      expect(s.gap / full.gap,
          closeTo(s.barHeight / full.barHeight, 1e-9));
    });
  });

  group('staff spacing no longer touches the row', () {
    // The old design folded an annotation reserve into spacingSystem and floored
    // it, which is what put a dead zone at the bottom of the slider: every value
    // below the default engraved the same gap. Verovio reserves the row itself
    // now, so the preference maps straight through over its whole range.
    test('the slider is monotone across its whole range, with no dead zone', () {
      var previous = -1;
      final distinct = <int>{};
      for (var v = staffSpacingMin; v <= staffSpacingMax + 1e-9; v += 0.05) {
        final units = verovioSpacingSystemFor(v);
        expect(units, greaterThanOrEqualTo(previous));
        previous = units;
        distinct.add(units);
      }
      expect(distinct.length, greaterThan(8),
          reason: 'the slider should reach many distinct gaps, not a floor');
    });

    test('the minimum really does mean the smallest gap available', () {
      expect(verovioSpacingSystemFor(staffSpacingMin), 0);
    });
  });

  // ── The reserve: asking Verovio for the room instead of shrinking to fit ────

  group('the annotation reserve', () {
    test('is priced from the measured per-unit yields', () {
      // One spacingSystem unit = half a staff space, one pageMarginTop unit =
      // 1/18. Both measured across every fixture, both orientations, at Verovio
      // scale 40 and 80. If Verovio ever changes these the constants below are
      // wrong and everything downstream quietly under-reserves, so pin them.
      expect(spacesPerSpacingSystemUnit, 0.5);
      expect(spacesPerPageMarginTopUnit, closeTo(1 / 18, 1e-12));
      expect(annotationSpacingSystemUnits, 7);
      expect(annotationPageMarginTopUnits, 63);
    });

    test('buys the same room in both places', () {
      expect(
        annotationSpacingSystemUnits * spacesPerSpacingSystemUnit,
        greaterThanOrEqualTo(annotationRoomSpaces),
      );
      expect(
        annotationPageMarginTopUnits * spacesPerPageMarginTopUnit,
        greaterThanOrEqualTo(annotationRoomSpaces),
      );
    });

    test('is ADDED to the preference, never floored over it', () {
      // The distinction that killed the previous version of this: a floor made
      // every staff spacing below the default engrave the same gap, so the bottom
      // half of that slider did nothing.
      for (var v = staffSpacingMin; v <= staffSpacingMax + 1e-9; v += 0.05) {
        expect(
          verovioSpacingSystemForEngrave(v, annotationRoom: true),
          verovioSpacingSystemFor(v) + annotationSpacingSystemUnits,
        );
      }
    });

    test('leaves the slider its whole range, with no dead zone', () {
      var previous = -1;
      final distinct = <int>{};
      for (var v = staffSpacingMin; v <= staffSpacingMax + 1e-9; v += 0.05) {
        final units = verovioSpacingSystemForEngrave(v, annotationRoom: true);
        expect(units, greaterThanOrEqualTo(previous));
        previous = units;
        distinct.add(units);
      }
      expect(distinct.length, greaterThan(8));
    });

    test('a score with nothing to draw pays nothing', () {
      for (final v in [staffSpacingMin, staffSpacingDefault, staffSpacingMax]) {
        expect(
          verovioSpacingSystemForEngrave(v, annotationRoom: false),
          verovioSpacingSystemFor(v),
        );
      }
      expect(
        verovioPageMarginTopForEngrave(annotationRoom: false),
        verovioPageMarginTopDefault,
      );
    });

    test('the top margin stays inside what Verovio honours', () {
      // Measured: 500 works, 510 silently reverts to the default layout — no
      // warning, so an over-large value reads as "the reserve does not work".
      expect(
        verovioPageMarginTopForEngrave(annotationRoom: true),
        lessThanOrEqualTo(verovioPageMarginTopMax),
      );
      expect(
        verovioPageMarginTopForEngrave(annotationRoom: true),
        verovioPageMarginTopDefault + annotationPageMarginTopUnits,
      );
    });

    test('stays inside the 0..48 Verovio accepts, even at the top', () {
      expect(
        verovioSpacingSystemForEngrave(staffSpacingMax, annotationRoom: true),
        inInclusiveRange(0, 48),
      );
    });
  });

  group('who gets the reserve', () {
    // A property of the score, so no display toggle can move it — that is what
    // keeps the chord-symbol switch a repaint rather than a re-engrave.
    test('the annotated view does: it injects fingerings and keeps harmony', () {
      expect(
        scoreReservesAnnotationRoom(
          '<note><notations><technical><fingering>0</fingering>'
          '</technical></notations></note>',
        ),
        isTrue,
      );
    });

    test('the tab view does: harmony alone is still a row to draw', () {
      expect(
        scoreReservesAnnotationRoom('<harmony><root/></harmony><note/>'),
        isTrue,
      );
    });

    test('the plain staff view does not — it strips both', () {
      expect(scoreReservesAnnotationRoom('<note><pitch/></note>'), isFalse);
    });
  });

  group('the reserve against the measured library', () {
    // Room from the previous system's ink to the annotation register, in staff
    // spaces, at Verovio's own default spacingSystem of 4 — measured on every
    // fixture in assets/fixtures, engraved headlessly with a `<fingering>`
    // placeholder on every non-rest note (Verovio 6.2.0, scale 40).
    //
    // The two entries carrying `<harmony>` draw BOTH rows; every other fixture
    // draws the fingering row alone, because with no engraved `<harm>` there is
    // no register and no bar is ever painted.
    const roomAtDefault = <String, double>{
      'abc_05_o_come_little_children': 2.31,
      'abc_10_allegretto': 2.26,
      'abc_14_minuet_no_2': 2.26,
      'abc_15_minuet_no_3': 2.26,
      'abc_17_gavotte': 2.26,
      'gossec_gavotte': 2.25,
      'happy_farmer_musescore': 2.03,
      'homr_05_o_come_little_children': 2.82,
      'homr_10_allegretto': 2.81,
      'homr_14_minuet_no_2': 1.84, // the tightest in the library
      'homr_15_minuet_no_3': 2.81,
      'homr_17_gavotte': 2.81,
      'the_wellerman': 3.06,
      'lightly_row_musescore': 4.06, // + harmony
      'old_joe_clark': 3.62, // + harmony
    };
    const withHarmony = {'lightly_row_musescore', 'old_joe_clark'};

    // Room above the FIRST system at Verovio's default pageMarginTop of 50, same
    // engraves. Its own case because system 0 has no system above it to borrow
    // from — the page's top margin is all it has, and this is the number that
    // becomes the score-wide minimum if the margin is not reserved for too.
    const firstSystemRoomAtDefault = 3.92;

    test('every fixture reaches its full stack once the reserve is added', () {
      for (final e in roomAtDefault.entries) {
        final harmony = withHarmony.contains(e.key);
        final full = annotationStackFor(
          budgetPx: double.infinity,
          staffSpacePx: space,
          labelShare: chordLabelSizeFraction,
          typeShare: typeShare,
          withChordBar: harmony,
        );
        final want = full.barHeight + full.channelHeight + full.gap;
        final got = annotationStackFor(
          budgetPx: (e.value + annotationRoomSpaces) * space,
          staffSpacePx: space,
          labelShare: chordLabelSizeFraction,
          typeShare: typeShare,
          withChordBar: harmony,
        );
        expect(
          got.channelHeight,
          closeTo(full.channelHeight, 1e-9),
          reason: '${e.key}: ${e.value} + $annotationRoomSpaces spaces still '
              'short of ${(want / space).toStringAsFixed(2)}',
        );
      }
    });

    test('and the tightest of them would NOT without it', () {
      final full = stack(double.infinity);
      final short = stack(1.84 * space);
      expect(short.channelHeight, lessThan(full.channelHeight));
    });

    test('the first system is covered too', () {
      final full = stack(double.infinity);
      final got =
          stack((firstSystemRoomAtDefault + annotationRoomSpaces) * space);
      expect(got.channelHeight, closeTo(full.channelHeight, 1e-9));
      expect(got.barHeight, closeTo(full.barHeight, 1e-9));
    });
  });

  group('only the rows this score draws claim room', () {
    // Most of the library carries no <harmony>, so harmRegister is null on every
    // system and no bar is ever painted. Charging those scores for a bar they
    // will not draw was worth an extra 2 units of reserve — a system a quarter
    // taller — for space nothing occupies.
    test('no harmony means no bar, and no bar in the appetite', () {
      final one = annotationStackFor(
        budgetPx: double.infinity,
        staffSpacePx: space,
        labelShare: chordLabelSizeFraction,
        typeShare: typeShare,
        withChordBar: false,
      );
      expect(one.barHeight, 0);
      expect(one.gap, 0);
      expect(
        one.channelHeight,
        closeTo(stack(double.infinity).channelHeight, 1e-9),
      );
      // The room a fingering-only score has at Verovio's default (2.03 on Happy
      // Farmer) plus the reserve clears the channel outright, where against the
      // two-row appetite it would still have been shrinking.
      final got = annotationStackFor(
        budgetPx: (2.03 + annotationRoomSpaces) * space,
        staffSpacePx: space,
        labelShare: chordLabelSizeFraction,
        typeShare: typeShare,
        withChordBar: false,
      );
      expect(got.channelHeight, closeTo(one.channelHeight, 1e-9));
      expect(
        stack((2.03 + annotationRoomSpaces) * space).channelHeight,
        lessThan(one.channelHeight),
      );
    });

    test('the tab view is the mirror image: a bar and no channel', () {
      final s = annotationStackFor(
        budgetPx: double.infinity,
        staffSpacePx: space,
        labelShare: chordLabelSizeFraction,
        typeShare: typeShare,
        withFingeringRow: false,
      );
      expect(s.channelHeight, 0);
      expect(s.gap, 0, reason: 'nothing below the bar to keep clear of');
      expect(s.barHeight, closeTo(stack(double.infinity).barHeight, 1e-9));
    });

    test('neither row means no stack at all, not a negative one', () {
      final s = annotationStackFor(
        budgetPx: 100,
        staffSpacePx: space,
        labelShare: chordLabelSizeFraction,
        typeShare: typeShare,
        withChordBar: false,
        withFingeringRow: false,
      );
      expect(s.barHeight, 0);
      expect(s.channelHeight, 0);
      expect(s.gap, 0);
    });
  });
}

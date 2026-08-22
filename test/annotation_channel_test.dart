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
    // Measured on Old Joe Clark: 3.67 staff spaces available at the tightest
    // system against 5.72 wanted, so this is the normal case, not the edge one.
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
}

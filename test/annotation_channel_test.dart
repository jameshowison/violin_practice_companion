import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/violin_string_palette.dart';
// For the staffSpacing slider bounds — the channel has to hold across the whole
// range the user can actually drag to, not just the values we picked.
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';

/// The annotation channel: how tall a register's row is, and where it sits.
///
/// Replaces the old lane-reservation suite. That tested a reserve asked of
/// Verovio in MEI units, a lane height taken as a fraction of the system's ink
/// extent, and a `laneSqueeze` that scaled every lane in the score by its
/// tightest gap. None of those exist now — the annotations are engraved, so
/// Verovio reserves their space itself, and the app reads back the baseline it
/// chose. What is left to pin down is the height the row wants and the one clamp
/// that remains.
///
/// The properties carried over from the old suite, because they must still hold:
/// the row is uniform across systems, and a system with no room degrades rather
/// than colliding.
void main() {
  // A staff space at the engraver's probe scale: staffHeightUnits × 40 / 100 / 4.
  const space = 7.2;
  final typeShare = underlineTextFraction;

  group('annotationChannelHeightFor', () {
    test('is exactly tall enough for full-size type in the tallest style', () {
      final h = annotationChannelHeightFor(
        staffSpacePx: space,
        typeShare: typeShare,
      );
      // The underline style spends only typeShare of the channel on type, so the
      // channel has to be that much taller for the type to come out full size.
      expect(h * typeShare, closeTo(annotationFontSizeFor(space), 1e-9));
    });

    test('the chip styles are never the binding constraint', () {
      final h = annotationChannelHeightFor(
        staffSpacePx: space,
        typeShare: typeShare,
      );
      // A chip wants font / 0.78, and takes at most 0.88 of the channel.
      const chipTypeFraction = 0.78;
      const chipChannelFraction = 0.88;
      expect(
        annotationFontSizeFor(space) / chipTypeFraction,
        lessThan(h * chipChannelFraction),
        reason: 'a chip would be clamped by the channel the underline sized',
      );
    });

    test('is scale-invariant — the row holds its size against the notes', () {
      final small = annotationChannelHeightFor(
        staffSpacePx: space,
        typeShare: typeShare,
      );
      final big = annotationChannelHeightFor(
        staffSpacePx: space * 3,
        typeShare: typeShare,
      );
      expect(big / small, closeTo(3.0, 1e-9));
    });

    test('degenerate inputs yield nothing, not a negative height', () {
      expect(
        annotationChannelHeightFor(staffSpacePx: 0, typeShare: typeShare),
        0,
      );
      expect(annotationChannelHeightFor(staffSpacePx: space, typeShare: 0), 0);
      expect(
        annotationChannelHeightFor(staffSpacePx: -space, typeShare: typeShare),
        0,
      );
    });
  });

  group('annotationChannel', () {
    ({double top, double bottom})? channel({
      required double registerPx,
      required double ceilingPx,
    }) => annotationChannel(
      registerPx: registerPx,
      ceilingPx: ceilingPx,
      staffSpacePx: space,
      typeShare: typeShare,
    );

    test('sits ON the register, and rises from it', () {
      final c = channel(registerPx: 100, ceilingPx: 0)!;
      expect(c.bottom, 100, reason: 'the floor is the engraved baseline');
      expect(c.top, lessThan(c.bottom));
    });

    test('takes its full height when there is room', () {
      final c = channel(registerPx: 100, ceilingPx: 0)!;
      expect(
        c.bottom - c.top,
        closeTo(
          annotationChannelHeightFor(staffSpacePx: space, typeShare: typeShare),
          1e-9,
        ),
      );
    });

    test('is clamped by the system above, rather than colliding with it', () {
      final full = channel(registerPx: 100, ceilingPx: 0)!;
      final tight = channel(registerPx: 100, ceilingPx: 96)!;
      expect(tight.bottom - tight.top, 4);
      expect(tight.top, 96, reason: 'stops exactly at the ink above');
      expect(tight.bottom - tight.top, lessThan(full.bottom - full.top));
    });

    // The property the old laneSqueeze got wrong, and the reason for this rewrite.
    test('one cramped system does not affect any other', () {
      final cramped = channel(registerPx: 100, ceilingPx: 98)!;
      final roomy = channel(registerPx: 300, ceilingPx: 200)!;
      expect(cramped.bottom - cramped.top, 2);
      expect(
        roomy.bottom - roomy.top,
        closeTo(
          annotationChannelHeightFor(staffSpacePx: space, typeShare: typeShare),
          1e-9,
        ),
        reason: 'the roomy system keeps its full height',
      );
    });

    test('systems with room are uniform, so the row reads as one register', () {
      final heights = [
        for (final r in [100.0, 240.0, 380.0])
          channel(registerPx: r, ceilingPx: r - 100)!,
      ].map((c) => c.bottom - c.top).toSet();
      expect(heights, hasLength(1));
    });

    test('no room at all draws nothing rather than a zero-height row', () {
      expect(channel(registerPx: 100, ceilingPx: 100), isNull);
      expect(
        channel(registerPx: 100, ceilingPx: 120),
        isNull,
        reason: 'ink already overlapping the register',
      );
    });

    test('degenerate staff space yields nothing', () {
      expect(
        annotationChannel(
          registerPx: 100,
          ceilingPx: 0,
          staffSpacePx: 0,
          typeShare: typeShare,
        ),
        isNull,
      );
    });
  });

  group('staff spacing no longer touches the row', () {
    // The old design folded an annotation reserve into spacingSystem and floored
    // it, which is what put a dead zone at the bottom of the slider: every value
    // below the default engraved the same gap. Verovio reserves the row itself
    // now, so the preference maps straight through over its whole range.
    test(
      'the slider is monotone across its whole range, with no dead zone',
      () {
        var previous = -1;
        var distinct = <int>{};
        for (var v = staffSpacingMin; v <= staffSpacingMax + 1e-9; v += 0.05) {
          final units = verovioSpacingSystemFor(v);
          expect(units, greaterThanOrEqualTo(previous));
          previous = units;
          distinct.add(units);
        }
        expect(
          distinct.length,
          greaterThan(8),
          reason:
              'the slider should reach many distinct gaps, not sit on a floor',
        );
      },
    );

    test('the minimum really does mean the smallest gap available', () {
      expect(verovioSpacingSystemFor(staffSpacingMin), 0);
    });
  });
}

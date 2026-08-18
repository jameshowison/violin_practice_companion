import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/providers.dart'
    show staffSpacingDefault, staffSpacingMax, staffSpacingMin;
import 'package:violin_practice_companion/services/staff_zoom.dart';
import 'package:violin_practice_companion/widgets/section_minimap.dart';

/// A synthetic engraving: [perLine] measures on each successive system,
/// systems stacked 100 apart, measures 200 wide.
List<Rect> engraving(List<int> perLine, {double staffHeight = 60}) {
  final rects = <Rect>[];
  for (var line = 0; line < perLine.length; line++) {
    final top = line * 100.0;
    for (var m = 0; m < perLine[line]; m++) {
      rects.add(Rect.fromLTWH(m * 200.0, top, 200, staffHeight));
    }
  }
  return rects;
}

void main() {
  group('systemLinesOf', () {
    test('groups measures by system', () {
      final (lines, bands) = systemLinesOf(engraving([4, 4, 2]));
      expect(lines, [0, 0, 0, 0, 1, 1, 1, 1, 2, 2]);
      expect(bands.length, 3);
    });

    test('one measure per system is NOT folded onto a single line', () {
      // Regression: every system's lone measure starts at the same x, so a
      // "new line only where x resets LEFTWARD" test saw one line of 16 —
      // which collapsed the section/selection bands and made the
      // measures-per-line readout report the whole piece. Reachable as soon as
      // the zoom control allows 1 measure per line.
      final (lines, bands) = systemLinesOf(engraving(List.filled(16, 1)));
      expect(lines, List.generate(16, (i) => i));
      expect(bands.length, 16);
      expect(measuresPerLineOf(lines), 1);
    });

    test('a low note stretching one system does not merge it with the next', () {
      // First system's box reaches down into the next system's vertical band;
      // the x-reset rule still separates them.
      final rects = [
        Rect.fromLTWH(0, 0, 200, 150), // tall: overlaps the next system's top
        Rect.fromLTWH(200, 0, 200, 60),
        Rect.fromLTWH(0, 100, 200, 60), // new system, x resets
        Rect.fromLTWH(200, 100, 200, 60),
      ];
      expect(systemLinesOf(rects).$1, [0, 0, 1, 1]);
    });

    test('bands tile: adjacent lines touch with no gap and no overlap', () {
      final (_, bands) = systemLinesOf(engraving([4, 4, 4]));
      for (var i = 0; i < bands.length - 1; i++) {
        expect(bands[i].bottom, bands[i + 1].top);
      }
      // The outer edges hug the actual content.
      expect(bands.first.top, 0);
      expect(bands.last.bottom, 260); // line 2 top 200 + height 60
    });

    test('empty input', () {
      final (lines, bands) = systemLinesOf(const []);
      expect(lines, isEmpty);
      expect(bands, isEmpty);
    });
  });

  group('lineContentOf', () {
    test('is the raw union of each line\'s measure boxes', () {
      final rects = engraving([4, 4, 2]);
      final content = lineContentOf(rects, systemLinesOf(rects).$1);
      expect(content.length, 3);
      expect(content[0], (top: 0.0, bottom: 60.0));
      expect(content[1], (top: 100.0, bottom: 160.0));
      expect(content[2], (top: 200.0, bottom: 260.0));
    });

    test('a tall measure stretches only its own line', () {
      final rects = [
        Rect.fromLTWH(0, 0, 200, 60),
        Rect.fromLTWH(200, 0, 200, 90), // low note
        Rect.fromLTWH(0, 100, 200, 60),
      ];
      final content = lineContentOf(rects, systemLinesOf(rects).$1);
      expect(content[0], (top: 0.0, bottom: 90.0));
      expect(content[1], (top: 100.0, bottom: 160.0));
    });

    test('sits INSIDE the tiled bands — which is the whole point', () {
      // The tiled bands deliberately meet at the midpoint of the inter-system
      // gap, so `bands[l].top` is already in the whitespace and cannot answer
      // "where does the ink start?". These extents can — and the difference
      // between them is exactly the room the chord lane is drawn in.
      final rects = engraving([4, 4, 4]);
      final (lines, bands) = systemLinesOf(rects);
      final content = lineContentOf(rects, lines);
      for (var l = 1; l < content.length; l++) {
        expect(content[l].top, greaterThan(bands[l].top));
        expect(content[l].top - content[l - 1].bottom, 40); // the real gap
      }
      // Line 0 has no system above it, so there the two agree.
      expect(content.first.top, bands.first.top);
    });

    test('empty input', () {
      expect(lineContentOf(const [], const []), isEmpty);
    });
  });

  group('verovioSpacingSystemFor', () {
    // The "Staff spacing" slider had only ever been wired to the OSMD fallback
    // (MinSkyBottomDistBetweenSystems), so it was a no-op under the default
    // Verovio renderer. This is the Verovio-side mapping.
    test('the slider default reproduces Verovio\'s own default, so wiring it up '
        'changed nothing at the default position', () {
      // 4 is Verovio's default, established by measurement: with the option
      // unset the probe engrave was 293px tall, which 4 reproduces (12 gave
      // 351px). Getting this wrong silently spread every score out.
      expect(verovioSpacingSystemFor(staffSpacingDefault), 4);
    });

    test('the top of the slider reaches a genuinely airy layout', () {
      expect(verovioSpacingSystemFor(staffSpacingMax), 36);
    });

    test('increases monotonically across the slider range', () {
      var previous = -1;
      for (var v = staffSpacingMin; v <= staffSpacingMax; v += 0.05) {
        final s = verovioSpacingSystemFor(v);
        expect(s, greaterThanOrEqualTo(previous), reason: 'spacing=$v');
        previous = s;
      }
    });

    test('stays inside the range Verovio accepts', () {
      for (final v in [0.0, -1.0, staffSpacingMin, staffSpacingMax, 99.0]) {
        expect(verovioSpacingSystemFor(v), inInclusiveRange(0, 48));
      }
    });

    test('spans a usefully wide range end to end', () {
      expect(verovioSpacingSystemFor(staffSpacingMin),
          lessThan(verovioSpacingSystemFor(staffSpacingDefault)));
      expect(verovioSpacingSystemFor(staffSpacingMax),
          greaterThan(verovioSpacingSystemFor(staffSpacingDefault) * 2));
    });

    test('has usable resolution just above the default, where it matters', () {
      // The curve compresses the bottom half; check the region a user actually
      // nudges still yields distinct steps rather than a flat spot.
      final steps = [
        for (var v = 0.5; v <= 1.0001; v += 0.1) verovioSpacingSystemFor(v)
      ];
      expect(steps.toSet().length, steps.length, reason: 'flat spot in $steps');
    });
  });

  group('sectionMarkerScaleFor', () {
    test('the A/B markers grow as the measures-per-line drops', () {
      // 11pt base font ⇒ the sizes the control was specified against.
      expect(sectionMarkerScaleFor(8) * 11, closeTo(11, 0.01));
      expect(sectionMarkerScaleFor(5) * 11, closeTo(16.5, 0.01));
      expect(sectionMarkerScaleFor(2) * 11, closeTo(27.5, 0.01));
    });

    test('is monotonically non-increasing in measures-per-line', () {
      var previous = 0.0;
      for (var n = measuresPerLineMax; n >= measuresPerLineMin; n--) {
        final s = sectionMarkerScaleFor(n);
        expect(s, greaterThanOrEqualTo(previous), reason: 'n=$n');
        previous = s;
      }
    });

    test('never shrinks below the base size', () {
      for (var n = 0; n <= 40; n++) {
        expect(sectionMarkerScaleFor(n), greaterThanOrEqualTo(1.0));
      }
      expect(sectionMarkerScaleFor(null), 1.0); // before the first engrave
    });

    test('uses few, coarse steps so the markers do not drift with every reflow', () {
      final steps = {
        for (var n = measuresPerLineMin; n <= measuresPerLineMax; n++)
          sectionMarkerScaleFor(n)
      }.toList()
        ..sort();
      expect(steps.length, lessThanOrEqualTo(5));
      for (var i = 0; i < steps.length - 1; i++) {
        expect(steps[i + 1] / steps[i], greaterThanOrEqualTo(1.2),
            reason: 'steps ${steps[i]} → ${steps[i + 1]} are too close to read apart');
      }
    });

    test('the minimap strip width does NOT depend on the marker scale', () {
      // The load-bearing invariant: the strip is a Row sibling of the notation,
      // so a zoom-dependent width would close a positive feedback loop (wider
      // strip → narrower notation → auto picks fewer measures per line → bigger
      // markers → wider strip). Observed cascading 6 → 4 → 3 across three extra
      // engraves before the width was pinned. A plain const is the guarantee.
      expect(SectionMinimap.width, isA<double>());
      expect(SectionMinimap.width, 44);
    });
  });

  group('measuresPerLineOf', () {
    test('is the median over full systems, ignoring the short last one', () {
      // 4 + 4 + 4 + 1: the trailing single-measure system must not drag the
      // median down (it's the remainder, not the layout).
      final measureLine = [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3];
      expect(measuresPerLineOf(measureLine), 4);
    });

    test('a single system counts itself (nothing else to go on)', () {
      expect(measuresPerLineOf([0, 0, 0]), 3);
    });

    test('takes the median, not the mean, so one odd system does not skew it', () {
      // 3, 3, 8, 3, then a short one.
      final measureLine = [
        0, 0, 0,
        1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2,
        3, 3, 3,
        4,
      ];
      expect(measuresPerLineOf(measureLine), 3);
    });

    test('empty score yields 0', () {
      expect(measuresPerLineOf(const []), 0);
    });
  });

  group('unitsPerMeasureFrom', () {
    test('divides the page width across the measures on a line', () {
      expect(
        unitsPerMeasureFrom(pageWidthUnits: 12000, measuresPerLine: 4),
        3000,
      );
    });

    test('degenerate inputs yield 0 rather than infinity/NaN', () {
      expect(unitsPerMeasureFrom(pageWidthUnits: 12000, measuresPerLine: 0), 0);
      expect(unitsPerMeasureFrom(pageWidthUnits: 0, measuresPerLine: 4), 0);
    });
  });

  group('scaleFor', () {
    test('round-trips the calibration, less the fit slack: solving for the '
        'measured n returns the scale it was measured at', () {
      // A probe at scale 40 over a 1200px viewport engraves a
      // 1200*100/40 = 3000-unit page; 4 measures on it ⇒ 750 units each. Asking
      // for 4 again returns the probe scale, backed off by staffFitSlack so the
      // solve doesn't sit exactly on Verovio's fit boundary.
      const widthPx = 1200.0;
      final upm = unitsPerMeasureFrom(pageWidthUnits: 3000, measuresPerLine: 4);
      expect(
        scaleFor(widthPx: widthPx, unitsPerMeasure: upm, n: 4),
        closeTo(staffScaleProbe / staffFitSlack, 0.001),
      );
    });

    test('the slack widens the page but stays well under one whole measure, so '
        'it can never admit an extra one', () {
      const upm = 750.0;
      const widthPx = 1200.0;
      for (var n = measuresPerLineMin; n <= measuresPerLineMax; n++) {
        final scale = scaleFor(widthPx: widthPx, unitsPerMeasure: upm, n: n);
        if (scale == staffScaleMin || scale == staffScaleMax) continue; // clamped
        final pageWidthUnits = widthPx * 100 / scale;
        expect(pageWidthUnits, greaterThan(n * upm)); // room for n
        expect(pageWidthUnits, lessThan((n + 1) * upm)); // but not for n+1
      }
    });

    test('decreases monotonically in n — fewer measures means bigger notes', () {
      const upm = 750.0;
      var previous = double.infinity;
      for (var n = measuresPerLineMin; n <= measuresPerLineMax; n++) {
        final s = scaleFor(widthPx: 1200, unitsPerMeasure: upm, n: n);
        expect(s, lessThan(previous), reason: 'n=$n should be smaller than n=${n - 1}');
        previous = s;
      }
    });

    test('clamps at both ends', () {
      // n=1 on a very wide screen would otherwise run away.
      expect(scaleFor(widthPx: 4000, unitsPerMeasure: 750, n: 1), staffScaleMax);
      // A huge unitsPerMeasure (a very dense piece) would otherwise vanish.
      expect(scaleFor(widthPx: 300, unitsPerMeasure: 90000, n: 8), staffScaleMin);
    });

    test('degenerate inputs fall back to the probe scale', () {
      expect(scaleFor(widthPx: 0, unitsPerMeasure: 750, n: 4), staffScaleProbe);
      expect(scaleFor(widthPx: 1200, unitsPerMeasure: 0, n: 4), staffScaleProbe);
      expect(scaleFor(widthPx: 1200, unitsPerMeasure: 750, n: 0), staffScaleProbe);
    });
  });

  group('tighterUnitsPerMeasure', () {
    test('keeps the smaller of two upper bounds', () {
      expect(tighterUnitsPerMeasure(447.5, 352.5), 352.5);
    });

    test('a looser observation cannot loosen the bound', () {
      // The corrective engrave usually packs loosely — it was given the room it
      // asked for — so this is the case that would oscillate if it were wrong.
      expect(tighterUnitsPerMeasure(352.5, 470), 352.5);
    });

    test('either side being 0 means "no estimate yet"', () {
      expect(tighterUnitsPerMeasure(0, 447.5), 447.5);
      expect(tighterUnitsPerMeasure(447.5, 0), 447.5);
      expect(tighterUnitsPerMeasure(0, 0), 0);
    });
  });

  // The bug this whole feedback loop exists for, in the numbers it was found
  // with: Old Joe Clark on `dev-iphone` in portrait, asked for 3 measures a line
  // and engraved 4, notes a quarter smaller than the screen could show.
  group('calibration refinement — measured on dev-iphone', () {
    const widthPx = 358.0;
    const phone = 402.0;

    test('a probe at 2 bars a line over-estimates, the engrave corrects it', () {
      // 1. Probe at scale 40 fit 2 bars in an 895-unit page.
      var upm = tighterUnitsPerMeasure(
          0, unitsPerMeasureFrom(pageWidthUnits: 895, measuresPerLine: 2));
      expect(upm, 447.5);

      final target = autoMeasuresPerLine(
        widthPx: widthPx,
        viewportHeightPx: 658,
        shortestSidePx: phone,
        unitsPerMeasure: upm,
        systemHeightPx: 83.8,
        measureCount: 18,
      );
      expect(target, 3);
      final first = scaleFor(widthPx: widthPx, unitsPerMeasure: upm, n: target);
      expect(first, closeTo(25.4, 0.1));

      // 2. At that scale the page is 1410 units — and Verovio packed 4 bars into
      //    it, which is the observation the probe could not make.
      upm = tighterUnitsPerMeasure(
          upm, unitsPerMeasureFrom(pageWidthUnits: 1410, measuresPerLine: 4));
      expect(upm, closeTo(352.5, 0.1));

      // 3. Same target, corrected scale: bigger notes, and 3 bars a line as
      //    asked (measured: the corrective engrave achieved mpl 3).
      final second = scaleFor(widthPx: widthPx, unitsPerMeasure: upm, n: target);
      expect(second, closeTo(32.2, 0.2));
      expect(second / first, greaterThan(1.25));
      // Comfortably past the 3% threshold the widget requires to re-engrave.
      expect((second - first) / first, greaterThan(0.03));
    });

    test('Happy Farmer needs no correction — its bars really are that wide', () {
      // Same probe reading (895/2), but the engrave at scale 25.4 achieved
      // exactly the 3 it was asked for, so 1410/3 = 470 is a LOOSER bound and
      // the reference piece is left alone.
      final upm = tighterUnitsPerMeasure(
          447.5, unitsPerMeasureFrom(pageWidthUnits: 1410, measuresPerLine: 3));
      expect(upm, 447.5);
      expect(scaleFor(widthPx: widthPx, unitsPerMeasure: upm, n: 3),
          closeTo(25.4, 0.1));
    });
  });

  group('annotation type size', () {
    // Will The Circle Be Unbroken, portrait, 4 measures a line: scale 34.0, so a
    // staff space is 0.72 × 34 / 4 = 6.12 viewBox px, and the fingering channel
    // came out 15.0px tall (contentH 53.2 × 0.30 × squeeze 0.94).
    const space = 6.12;
    const channel = 15.0;

    /// Inked height of a digit at [fontSize], in staff spaces — the thing the
    /// eye compares against a notehead (which is exactly one space).
    double capSpaces(double fontSize) =>
        fontSize * labelCapHeightRatio / space;

    test('a digit inks slightly larger than a notehead', () {
      final f = annotationFontSizeFor(space);
      expect(capSpaces(f), closeTo(annotationCapHeightSpaces, 0.001));
      expect(capSpaces(f), greaterThan(1.0)); // bigger than a notehead...
      expect(capSpaces(f), lessThan(1.5)); // ...but not a second voice
    });

    test('beats what the old lane-derived chain produced', () {
      // Old: channel → chip zone (×0.22/0.30) → chip (×0.80) → type (×0.66).
      const old = channel * (0.22 / 0.30) * 0.80 * 0.66;
      expect(capSpaces(old), closeTo(0.67, 0.02)); // two thirds of a notehead
      expect(annotationFontSizeFor(space), greaterThan(old * 1.5));
    });

    test('the lane this piece has can host the wanted size', () {
      // The whole point of the diagnosis: the room was already there.
      expect(
        annotationFontSizeIn(staffSpacePx: space, laneHeightPx: channel),
        closeTo(annotationFontSizeFor(space), 0.001),
      );
    });

    test('scale-invariant — a label holds its size against the notes', () {
      // Two zoom levels, same relative type size. This is what the
      // measures-per-line slider must not be able to break.
      for (final s in [3.0, 6.12, 12.0, 25.0]) {
        expect(annotationFontSizeFor(s) / s,
            closeTo(annotationFontSizeFor(space) / space, 1e-9));
      }
    });

    test('a lane too short clamps the type instead of overflowing it', () {
      const short = 6.0; // e.g. a heavy laneSqueeze
      final f = annotationFontSizeIn(
          staffSpacePx: space, laneHeightPx: short, laneTypeShare: 0.78);
      expect(f, lessThan(annotationFontSizeFor(space)));
      expect(f, closeTo(short * 0.78, 0.001));
      // Never taller than the lane it is drawn in.
      expect(f, lessThan(short));
    });

    test('degenerate inputs are quiet', () {
      expect(annotationFontSizeFor(0), 0);
      expect(annotationFontSizeFor(-1), 0);
      // No lane measured yet: fall back to the want rather than to zero.
      expect(annotationFontSizeIn(staffSpacePx: space, laneHeightPx: 0),
          annotationFontSizeFor(space));
    });
  });

  group('minStaffScaleFor', () {
    /// The physical staff height, in mm, that a Verovio [scale] comes out at on
    /// a screen of [ptPerInch] — the inverse of the conversion under test.
    double mmAt(double scale, double ptPerInch) =>
        scale * staffHeightUnits / 100 / ptPerInch * 25.4;

    test('round-trips the phone floor back to its millimetre constant', () {
      expect(mmAt(minStaffScaleFor(402), phonePtPerInch),
          closeTo(minStaffHeightMmPhone, 0.001));
    });

    test('round-trips the tablet floor back to its millimetre constant', () {
      expect(mmAt(minStaffScaleFor(834), tabletPtPerInch),
          closeTo(minStaffHeightMmTablet, 0.001));
    });

    test('a tablet floor is PHYSICALLY larger than a phone floor', () {
      final phoneMm = mmAt(minStaffScaleFor(402), phonePtPerInch);
      final tabletMm = mmAt(minStaffScaleFor(834), tabletPtPerInch);
      expect(tabletMm, greaterThan(phoneMm));
      // "Slightly" bigger — a different reading distance, not a different app.
      expect(tabletMm / phoneMm, lessThan(1.5));
    });

    test('classifies by shortest side, so orientation cannot change it', () {
      // iPhone 17: 402×874. iPad Pro 11: 834×1210.
      expect(minStaffScaleFor(402), minStaffScaleFor(402));
      expect(minStaffScaleFor(834), greaterThan(minStaffScaleFor(402)));
      expect(minStaffScaleFor(tabletShortestSidePx), minStaffScaleFor(834));
      expect(minStaffScaleFor(tabletShortestSidePx - 1), minStaffScaleFor(402));
    });

    test('the floor leaves the hard clamp room to work', () {
      // staffScaleMin is the clamp on every solve, including an explicit slider
      // setting; the auto floor sits above it, so the user can still ask for
      // smaller by hand than auto will ever choose.
      expect(minStaffScaleFor(402), greaterThan(staffScaleMin));
      expect(minStaffScaleFor(834), lessThan(staffScaleMax));
    });
  });

  group('maxMeasuresPerLineFor', () {
    test('is the largest n whose scale still clears the floor', () {
      const widthPx = 706.0;
      const upm = 441.0;
      const shortestSide = 402.0; // phone
      final n = maxMeasuresPerLineFor(
        widthPx: widthPx,
        unitsPerMeasure: upm,
        shortestSidePx: shortestSide,
      );
      expect(scaleFor(widthPx: widthPx, unitsPerMeasure: upm, n: n),
          greaterThanOrEqualTo(minStaffScaleFor(shortestSide)));
      if (n < measuresPerLineMax) {
        expect(scaleFor(widthPx: widthPx, unitsPerMeasure: upm, n: n + 1),
            lessThan(minStaffScaleFor(shortestSide)));
      }
    });

    test('a tablet gets no more measures per line than its floor allows', () {
      // Same piece, same render width, tablet class: the physically larger floor
      // can only ever reduce the count.
      int at(double shortestSide) => maxMeasuresPerLineFor(
            widthPx: 900,
            unitsPerMeasure: 441,
            shortestSidePx: shortestSide,
          );
      expect(at(834), lessThanOrEqualTo(at(402)));
    });

    test('stays inside the slider range', () {
      for (final w in [200.0, 706.0, 4000.0]) {
        for (final upm in [90.0, 441.0, 9000.0]) {
          final n = maxMeasuresPerLineFor(
              widthPx: w, unitsPerMeasure: upm, shortestSidePx: 402);
          expect(n, greaterThanOrEqualTo(measuresPerLineMin));
          expect(n, lessThanOrEqualTo(measuresPerLineMax));
        }
      }
    });

    test('uncalibrated inputs impose no ceiling', () {
      expect(
        maxMeasuresPerLineFor(
            widthPx: 0, unitsPerMeasure: 441, shortestSidePx: 402),
        measuresPerLineMax,
      );
      expect(
        maxMeasuresPerLineFor(
            widthPx: 706, unitsPerMeasure: 0, shortestSidePx: 402),
        measuresPerLineMax,
      );
    });
  });

  group('autoMeasuresPerLine', () {
    // A calibration standing in for an iPad-landscape engrave: 1200pt wide,
    // 750 MEI units per measure, and a system 180px tall AT staffScaleProbe.
    const widthPx = 1200.0;
    const upm = 750.0;
    const systemH = 180.0; // pixels at staffScaleProbe
    const iPadShortestSide = 834.0;

    test('a short piece takes the smallest n that fits 75% of the viewport', () {
      final n = autoMeasuresPerLine(
        widthPx: widthPx,
        viewportHeightPx: 800,
        shortestSidePx: iPadShortestSide,
        unitsPerMeasure: upm,
        systemHeightPx: systemH,
        measureCount: 8,
      );
      // Whatever it picks must fit the budget...
      final h = predictedHeightPx(
        widthPx: widthPx,
        unitsPerMeasure: upm,
        systemHeightPx: systemH,
        measureCount: 8,
        n: n,
      );
      expect(h, lessThanOrEqualTo(800 * staffAutoFillFraction));
      // ...and one step bigger (n-1) must not, or it wasn't the smallest.
      if (n > measuresPerLineMin) {
        final bigger = predictedHeightPx(
          widthPx: widthPx,
          unitsPerMeasure: upm,
          systemHeightPx: systemH,
          measureCount: 8,
          n: n - 1,
        );
        expect(bigger, greaterThan(800 * staffAutoFillFraction));
      }
    });

    test('a taller viewport affords bigger notes (n never increases)', () {
      int at(double h) => autoMeasuresPerLine(
            widthPx: widthPx,
            viewportHeightPx: h,
            shortestSidePx: iPadShortestSide,
            unitsPerMeasure: upm,
            systemHeightPx: systemH,
            measureCount: 12,
          );
      expect(at(1200), lessThanOrEqualTo(at(600)));
    });

    test('a piece too long to fit stops at the note-size floor', () {
      final n = autoMeasuresPerLine(
        widthPx: widthPx,
        viewportHeightPx: 500,
        shortestSidePx: iPadShortestSide,
        unitsPerMeasure: upm,
        systemHeightPx: systemH,
        measureCount: 400,
      );
      expect(
        n,
        maxMeasuresPerLineFor(
          widthPx: widthPx,
          unitsPerMeasure: upm,
          shortestSidePx: iPadShortestSide,
        ),
      );
    });

    test('never resolves below the device floor, at any length', () {
      for (final shortestSide in [402.0, 834.0]) {
        final floor = minStaffScaleFor(shortestSide);
        for (final count in [1, 8, 21, 32, 120, 400]) {
          final n = autoMeasuresPerLine(
            widthPx: widthPx,
            viewportHeightPx: 500,
            shortestSidePx: shortestSide,
            unitsPerMeasure: upm,
            systemHeightPx: systemH,
            measureCount: count,
          );
          final scale =
              scaleFor(widthPx: widthPx, unitsPerMeasure: upm, n: n);
          // One measure per line is the end of the road: a piece dense enough
          // that even that is below the floor has nowhere left to go.
          if (n > measuresPerLineMin) {
            expect(scale, greaterThanOrEqualTo(floor),
                reason: 'count=$count shortestSide=$shortestSide n=$n');
          }
        }
      }
    });

    test('an uncalibrated score falls back to the width breakpoint', () {
      expect(
        autoMeasuresPerLine(
          widthPx: 800,
          viewportHeightPx: 600,
          shortestSidePx: 402,
          unitsPerMeasure: 0,
          systemHeightPx: 0,
          measureCount: 0,
        ),
        measuresPerLineForWidth(800),
      );
    });
  });

  // Real calibrations, read off the `[engraver]` debug lines on `dev-iphone`, so
  // the two reference pieces are pinned: the tune whose size defined the floor
  // must not be made to scroll by it, and the tune that used to fall through the
  // floor must now stop at it.
  group('autoMeasuresPerLine — measured on dev-iphone', () {
    const phone = 402.0; // iPhone 17 shortest side

    test('Happy Farmer keeps its 3-per-line portrait layout', () {
      // probe: pageW 895 / mpl 2 ⇒ 447.5 units per measure, sysH 86.2, 21 bars.
      final n = autoMeasuresPerLine(
        widthPx: 358,
        viewportHeightPx: 686,
        shortestSidePx: phone,
        unitsPerMeasure: 447.5,
        systemHeightPx: 86.2,
        measureCount: 21,
      );
      expect(n, 3);
      // It IS the floor — that is where the constant came from — so it has to
      // land on the legal side of it.
      expect(scaleFor(widthPx: 358, unitsPerMeasure: 447.5, n: n),
          greaterThanOrEqualTo(minStaffScaleFor(phone)));
    });

    test('Happy Farmer keeps its 7-per-line landscape layout', () {
      // probe: pageW 1765 / mpl 5 ⇒ 353 units per measure, sysH 85.7.
      final n = autoMeasuresPerLine(
        widthPx: 706,
        viewportHeightPx: 282,
        shortestSidePx: phone,
        unitsPerMeasure: 353,
        systemHeightPx: 85.7,
        measureCount: 21,
      );
      expect(n, 7);
    });

    test('Gavotte stops at 6 rather than cramming 9 in at scale 20', () {
      // probe: pageW 1765 / mpl 4 ⇒ 441 units per measure, sysH 92.4, 32 bars.
      // Landscape phone; before the floor this resolved to 8 (Verovio engraved
      // 9) at scale 20 — 2.2mm of staff.
      const upm = 441.0;
      final n = autoMeasuresPerLine(
        widthPx: 706,
        viewportHeightPx: 282,
        shortestSidePx: phone,
        unitsPerMeasure: upm,
        systemHeightPx: 92.4,
        measureCount: 32,
      );
      expect(n, 6);
      expect(scaleFor(widthPx: 706, unitsPerMeasure: upm, n: n),
          greaterThanOrEqualTo(minStaffScaleFor(phone)));
    });
  });

  group('measuresPerLineForWidth', () {
    test('breakpoints', () {
      expect(measuresPerLineForWidth(1366), 4); // iPad landscape
      expect(measuresPerLineForWidth(1000), 4); // boundary, inclusive
      expect(measuresPerLineForWidth(999), 3);
      expect(measuresPerLineForWidth(768), 3); // iPad portrait
      expect(measuresPerLineForWidth(700), 3); // boundary, inclusive
      expect(measuresPerLineForWidth(699), 2);
      expect(measuresPerLineForWidth(390), 2); // phone
    });

    test('always inside the slider range', () {
      for (final w in [0.0, 320.0, 700.0, 1024.0, 4000.0]) {
        final n = measuresPerLineForWidth(w);
        expect(n, greaterThanOrEqualTo(measuresPerLineMin));
        expect(n, lessThanOrEqualTo(measuresPerLineMax));
      }
    });
  });

  group('pageHeightUnitsFor', () {
    // Only page 1 is ever rendered, so a page too short silently clips the
    // bottom of the score. Note the page's capacity IN SYSTEMS is
    // scale-invariant (zoom shrinks the page width in MEI units but leaves the
    // height and a system's unit height alone), so the floor covers ordinary
    // pieces at any zoom — this is insurance for the long tail.
    const systemH = 180.0; // px at staffScaleProbe ⇒ 450 MEI units
    test('an ordinary piece stays on the pre-zoom floor', () {
      expect(
        pageHeightUnitsFor(
            measureCount: 8, measuresPerLine: 4, systemHeightPx: systemH),
        60000,
      );
    });

    test('a very long piece at one bar per line outgrows the floor', () {
      final tall = pageHeightUnitsFor(
          measureCount: 200, measuresPerLine: 1, systemHeightPx: systemH);
      // 200 systems x 450 units x 1.5 headroom = 135000.
      expect(tall, 135000);
    });

    test('more measures per line means fewer systems means a shorter page', () {
      final at2 = pageHeightUnitsFor(
          measureCount: 400, measuresPerLine: 2, systemHeightPx: systemH);
      final at8 = pageHeightUnitsFor(
          measureCount: 400, measuresPerLine: 8, systemHeightPx: systemH);
      expect(at8, lessThan(at2));
    });

    test('converts px→MEI units by the scale it was measured at', () {
      // The same physical system measured at scale 80 reads twice as many px,
      // so it must convert back to the same MEI units — and hence the same page.
      expect(
        pageHeightUnitsFor(
            measureCount: 200,
            measuresPerLine: 1,
            systemHeightPx: systemH * 2,
            measuredAtScale: staffScaleProbe * 2),
        pageHeightUnitsFor(
            measureCount: 200, measuresPerLine: 1, systemHeightPx: systemH),
      );
    });

    test('degenerate inputs yield the floor', () {
      expect(
        pageHeightUnitsFor(
            measureCount: 0, measuresPerLine: 4, systemHeightPx: systemH),
        60000,
      );
      expect(
        pageHeightUnitsFor(
            measureCount: 8, measuresPerLine: 0, systemHeightPx: systemH),
        60000,
      );
    });
  });

  group('predictedHeightPx', () {
    // The units are the subtle part: systemHeightPx is measured at the probe
    // scale and is NOT scale-invariant, so the conversion is a scale RATIO.
    test('at the measured measures-per-line it reproduces the probe height', () {
      // Probe: 1200px wide at scale 40 ⇒ a 3000-unit page holding 4 measures,
      // so 750 units each. 16 measures ⇒ 4 systems of 180px = 720px — scaled
      // down by staffFitSlack, since asking for 4 again backs off the scale.
      const widthPx = 1200.0;
      final upm = unitsPerMeasureFrom(pageWidthUnits: 3000, measuresPerLine: 4);
      expect(
        predictedHeightPx(
          widthPx: widthPx,
          unitsPerMeasure: upm,
          systemHeightPx: 180,
          measureCount: 16,
          n: 4,
        ),
        closeTo(720 / staffFitSlack, 0.001),
      );
    });

    test('halving the measures per line roughly doubles the height twice over — '
        'twice as many systems, each twice as tall', () {
      const widthPx = 1200.0;
      final upm = unitsPerMeasureFrom(pageWidthUnits: 3000, measuresPerLine: 4);
      double at(int n) => predictedHeightPx(
            widthPx: widthPx,
            unitsPerMeasure: upm,
            systemHeightPx: 180,
            measureCount: 16,
            n: n,
          );
      // 4 systems x 180px = 720 → 8 systems x 360px = 2880.
      expect(at(2), closeTo(at(4) * 4, 0.001));
    });

    test('is monotonically decreasing in n', () {
      var previous = double.infinity;
      for (var n = measuresPerLineMin; n <= measuresPerLineMax; n++) {
        final h = predictedHeightPx(
          widthPx: 1200,
          unitsPerMeasure: 750,
          systemHeightPx: 180,
          measureCount: 64,
          n: n,
        );
        expect(h, lessThan(previous), reason: 'n=$n');
        previous = h;
      }
    });
  });
}

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

  group('autoMeasuresPerLine', () {
    // A calibration standing in for an iPad-landscape engrave: 1200pt wide,
    // 750 MEI units per measure, and a system 180px tall AT staffScaleProbe.
    const widthPx = 1200.0;
    const upm = 750.0;
    const systemH = 180.0; // pixels at staffScaleProbe

    test('a short piece takes the smallest n that fits 75% of the viewport', () {
      final n = autoMeasuresPerLine(
        widthPx: widthPx,
        viewportHeightPx: 800,
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
            unitsPerMeasure: upm,
            systemHeightPx: systemH,
            measureCount: 12,
          );
      expect(at(1200), lessThanOrEqualTo(at(600)));
    });

    test('a piece too long to fit falls back to the width breakpoint', () {
      final n = autoMeasuresPerLine(
        widthPx: widthPx,
        viewportHeightPx: 500,
        unitsPerMeasure: upm,
        systemHeightPx: systemH,
        measureCount: 400,
      );
      expect(n, measuresPerLineForWidth(widthPx));
    });

    test('an uncalibrated score falls back to the width breakpoint', () {
      expect(
        autoMeasuresPerLine(
          widthPx: 800,
          viewportHeightPx: 600,
          unitsPerMeasure: 0,
          systemHeightPx: 0,
          measureCount: 0,
        ),
        measuresPerLineForWidth(800),
      );
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

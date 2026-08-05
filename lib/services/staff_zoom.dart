/// Staff layout maths: turning a "measures per line" target into the Verovio
/// `scale` option, picking a sensible default from the viewport, and mapping the
/// staff-spacing preference onto Verovio's vertical spacing.
///
/// Deliberately pure (no Flutter, no Verovio) so it unit-tests directly.
///
/// ## Why measures-per-line and zoom are one knob
///
/// [VerovioEngraver] pins the engraved page to exactly the available render
/// width: `pageWidth(MEI units) = widthPx * 100 / scale`, and the widget then
/// draws the SVG 1:1 into that same width. Verovio lays out in MEI units, where
/// a measure's natural width is independent of `scale` — so raising `scale` at a
/// fixed `widthPx` narrows the page in units, which puts **fewer measures on
/// each system and makes every glyph bigger**. One lever, both effects.
///
/// ## Calibration
///
/// The bridge between the two is [unitsPerMeasureFrom]: the average engraved
/// width of one measure, in MEI units. It is invariant in both `scale` and
/// viewport width — a property of the piece alone — so a single probe engrave
/// calibrates it once, and every later target is closed-form ([scaleFor]). No
/// search loop.
///
/// Because Verovio keeps `breaks: 'auto'` (it still chooses musical break
/// points), the achieved count is approximate: a dense bar may yield one fewer.
/// The UI says "≈".
library;

import 'dart:ui' show Rect;

/// Verovio `scale` used for the calibration probe — the value the engraver
/// shipped with before zoom existed, so an un-zoomed piece hits the same cache
/// entry it always did.
const double staffScaleProbe = 40;

/// Clamp range for the solved Verovio `scale`. The floor keeps a wide screen
/// from engraving unreadably small; the ceiling guards a runaway page (and a
/// pathologically tall SVG) at `n = 1` on a very wide viewport.
const double staffScaleMin = 20;
const double staffScaleMax = 220;

/// Slider bounds for the measures-per-line target. Exposed as top-level consts
/// so a test can assert `min < max`: a zero-range [Slider] cannot claim drag
/// gestures and they leak to parent handlers (the settings Drawer's
/// swipe-to-close). See `test/staff_spacing_slider_test.dart`.
const int measuresPerLineMin = 1;
const int measuresPerLineMax = 8;

/// Fraction of the viewport the auto default aims to fill, leaving the rest as
/// breathing room. Only applies when the whole piece fits — see
/// [autoMeasuresPerLine].
const double staffAutoFillFraction = 0.75;

/// Extra page width asked for beyond the strict `n × unitsPerMeasure` solve.
///
/// [unitsPerMeasure] is measured from a *justified* engraving, so it is an
/// estimate of Verovio's natural minimum measure width — and a solve that lands
/// exactly on `n × minimum` is a coin flip. Measured on Lightly Row: the probe
/// gave 313 units/measure, a 1566-unit page fit exactly 5 (5 × 313 = 1565, just
/// inside), and a 626-unit page fit 1 rather than 2 (the true minimum was nearer
/// 313.5, so 2 needed 627). A few percent of slack moves off that knife edge; the
/// price is notes ~5% smaller than the theoretical maximum, which is invisible.
/// It stays far below one whole measure, so it can never admit an extra one.
const double staffFitSlack = 1.05;

/// Verovio's `spacingSystem` (vertical gap between systems, in MEI units) for a
/// given `staffSpacingProvider` value.
///
/// The OSMD fallback drives the same preference through
/// `MinSkyBottomDistBetweenSystems` / `MinimumDistanceBetweenSystems`; this is the
/// Verovio-side equivalent, which had simply never been connected.
///
/// Quadratic, pinned to two measured anchors:
///
/// * **0.5 (the slider default) → 4.** Verovio's own default is 4, established by
///   measurement, not documentation: before the option was passed at all, the
///   probe engrave came out 293px tall, and 293 is reproduced at 4 — whereas 12
///   gave 351px. Anchoring here means wiring the slider up did not change how a
///   score renders at the default slider position.
/// * **1.5 (the maximum) → 36**, which measured a comfortably airy layout (509px
///   for the same probe). A purely linear map through the first anchor would top
///   out at 12 and give the slider almost no reach above the default.
///
/// The curve costs some resolution below the default (0.1..0.5 spans only 0..4),
/// which is the half nobody adjusts — the interesting range sits just above 0.5,
/// where steps land ~1 unit apart. Clamped to the 0..48 Verovio accepts.
int verovioSpacingSystemFor(double staffSpacing) {
  if (staffSpacing <= 0) return 0;
  return (16 * staffSpacing * staffSpacing).round().clamp(0, 48);
}

/// Verovio's default `pageMarginTop` in MEI units. Set explicitly (rather than
/// left to the default) only so [verovioLaneMarginUnits] can be added to it.
/// Verified by measurement: passing 50 back reproduces the 31.9px above the first
/// system that the un-set option gave, so a 1-lane engrave is unchanged.
const int verovioPageMarginTopDefault = 50;

// ── Annotation-lane reservation ──────────────────────────────────────────────
//
// Room for annotation lanes past the first has to be asked of Verovio in TWO
// places, because the lanes live in two different kinds of whitespace: the page's
// top margin holds line 0's lanes, the inter-system gap holds every other line's.
//
// The first lane is free. Measurement (`[engraver] lane` debug line, 12-bar tune,
// default staff spacing) put the default layout at `top0 = 0.51 × contentH` and
// `gap1 = 0.38 × contentH`, against a per-lane appetite of
// `annotationLaneHeightFraction` = 0.30 plus clearance — so one lane already fits
// in both, which is what the chord lane has always drawn into. It's the SECOND
// lane that needs asking for.
//
// Both ratios above are scale-invariant (confirmed at scale 40 and 52.4: `top0`,
// `gap1` and `contentH` all move together), so these unit counts hold at every
// zoom level.
//
// The two knobs are NOT interchangeable — measured at the probe scale, one unit of
// `spacingSystem` is worth ~3.6px of gap while one unit of `pageMarginTop` is
// worth only ~0.4px. Reserving the same number of units in both over-reserves the
// gap by ~3×, so they get separately measured constants.
//
// ## Known consequence: the annotation view can reflow wider than the staff view
//
// Gap is not free. It inflates `systemHeightPx`, which is what
// [autoMeasuresPerLine] budgets against — and that budget has a CLIFF, not a
// slope: a piece whose whole-score height no longer fits the viewport doesn't
// shrink a little, it falls straight through to [measuresPerLineForWidth].
//
// Measured on a 12-bar tune sitting right at that boundary (`sysH` 75.8 before,
// budget somewhere under 80): a full-height channel takes it to 83.5 and the
// annotation view goes from 8 measures per line to 4, doubling the note size and
// making the piece scroll. A 1-unit reserve would have held 8, at the price of
// squeezing both lanes to 0.65 of their height.
//
// Full height was chosen deliberately over keeping the layout. Note the cliff
// only bites on AUTO measures-per-line; with an explicit setting from the slider
// the reserve just makes the score a little taller. That measurement was taken
// when the channel was 0.22; at 0.30 (the underline stagger) it costs one more
// spacing unit, so a piece sitting right at the boundary is that much likelier to
// fall through — the same trade, one notch further along.

/// `spacingSystem` units per annotation lane past the first.
///
/// Two lanes need `gap ≥ 0.30 + 0.30 + 2×0.05 = 0.70 × contentH`, up from the
/// default 0.38 — a 0.32 shortfall, and one unit buys 0.058, so ~5.5 units.
/// Rounded up to 6 so both lanes clear their full proportional height
/// (`EngravedScore.laneSqueeze` == 1.00) rather than landing a hair short.
const int laneReserveSpacingUnitsPerLane = 6;

/// `pageMarginTop` units per annotation lane past the first. Two lanes need
/// `top0 ≥ 0.30 + 0.30 + 0.05 = 0.65 × contentH` (only one clearance pad up here,
/// there being no system above to clear), up from the default 0.51 — a 0.14
/// shortfall at 0.0064 per unit, so ~22 units. Far more units than the gap needs
/// for the same room, because a margin unit is worth ~9× less.
const int laneReserveMarginUnitsPerLane = 22;

/// Extra `spacingSystem` for [lanes] annotation lanes. 0 for one lane, so a
/// staff- or tab-view engrave is bit-for-bit what it was before lanes stacked.
/// Clamped because nothing sensible asks for more than a handful.
int verovioLaneSpacingUnits(int lanes) =>
    (lanes - 1).clamp(0, 4) * laneReserveSpacingUnitsPerLane;

/// Extra `pageMarginTop` for [lanes] annotation lanes. 0 for one lane.
int verovioLaneMarginUnits(int lanes) =>
    (lanes - 1).clamp(0, 4) * laneReserveMarginUnitsPerLane;

/// Size multiplier for the section minimap's A/B part markers at a given achieved
/// measures-per-line, so they grow along with the notes.
///
/// Coarse steps keyed on the **integer** count rather than the continuous
/// engraving scale: the count is what the user sees in the "≈N" readout, so the
/// markers only change size when the layout visibly does, instead of drifting a
/// point at a time with every reflow.
///
/// The multiplier applies to the label and the emblem height only — never the
/// minimap's width, which must stay constant to avoid feeding back into the
/// notation's engraved width. See [SectionMinimap] for that mechanism.
double sectionMarkerScaleFor(int? measuresPerLine) {
  if (measuresPerLine == null || measuresPerLine <= 0) return 1;
  if (measuresPerLine >= 7) return 1;
  if (measuresPerLine >= 5) return 1.5;
  if (measuresPerLine >= 3) return 2;
  return 2.5;
}

/// Groups engraved measure boxes into system lines.
///
/// Returns, per measure, its line index, plus one **tiled** vertical band per
/// line whose boundaries sit at the midpoint between adjacent lines' content.
/// Tiling guarantees consecutive lines touch with zero gap and zero overlap, so
/// a full-height section or selection wash reads as clean, even bands regardless
/// of note heights.
///
/// [measureRects] must be in document order (as Verovio emits them).
(List<int>, List<({double top, double bottom})>) systemLinesOf(
    List<Rect> measureRects) {
  if (measureRects.isEmpty) return (const [], const []);
  final measureLine = List<int>.filled(measureRects.length, 0);
  final contentTop = <double>[];
  final contentBottom = <double>[];
  var line = -1;
  var prevLeft = double.negativeInfinity;
  for (var i = 0; i < measureRects.length; i++) {
    final r = measureRects[i];
    // A new system starts where the engraved x fails to ADVANCE — it either
    // resets leftward or repeats, and "repeats" is exactly what one measure per
    // system looks like (every system's lone measure shares the same left, so a
    // strict "reset leftward" test would fold the whole score onto one line).
    // Vertical extent is the cross-check: measures on one system always overlap
    // (they share the staff), stacked systems never do — which covers the case
    // where a very low note stretches a line's box down to touch the next.
    final xAdvanced = r.left > prevLeft + 1;
    final vOverlaps =
        line >= 0 && r.top < contentBottom[line] && r.bottom > contentTop[line];
    if (line < 0 || !xAdvanced || !vOverlaps) {
      line++;
      contentTop.add(r.top);
      contentBottom.add(r.bottom);
    } else {
      if (r.top < contentTop[line]) contentTop[line] = r.top;
      if (r.bottom > contentBottom[line]) contentBottom[line] = r.bottom;
    }
    measureLine[i] = line;
    prevLeft = r.left;
  }
  final n = contentTop.length;
  final bands = <({double top, double bottom})>[
    for (var l = 0; l < n; l++)
      (
        top: l == 0 ? contentTop[0] : (contentBottom[l - 1] + contentTop[l]) / 2,
        bottom: l == n - 1
            ? contentBottom[n - 1]
            : (contentBottom[l] + contentTop[l + 1]) / 2,
      )
  ];
  return (measureLine, bands);
}

/// Per system line, the RAW content extent — the union of that line's measure
/// boxes, indexed by the `measureLine` that [systemLinesOf] returns.
///
/// This is the counterpart to [systemLinesOf]'s **tiled** bands, whose
/// boundaries deliberately sit at the midpoint of the inter-system gap so a wash
/// reads as an even band. That tiling makes them useless for asking "where does
/// the ink actually start?" — `lineBands[l].top` is already inside the
/// whitespace. These extents are the true edges, so
/// `content[l].top - content[l-1].bottom` is the real gap between two systems:
/// the space the chord-run lane is drawn in.
List<({double top, double bottom})> lineContentOf(
    List<Rect> measureRects, List<int> measureLine) {
  final tops = <int, double>{};
  final bottoms = <int, double>{};
  var lines = 0;
  for (var i = 0; i < measureRects.length && i < measureLine.length; i++) {
    final l = measureLine[i];
    if (l < 0) continue;
    final r = measureRects[i];
    final top = tops[l];
    final bottom = bottoms[l];
    tops[l] = (top == null || r.top < top) ? r.top : top;
    bottoms[l] = (bottom == null || r.bottom > bottom) ? r.bottom : bottom;
    if (l + 1 > lines) lines = l + 1;
  }
  return [
    for (var l = 0; l < lines; l++)
      (top: tops[l] ?? 0.0, bottom: bottoms[l] ?? 0.0)
  ];
}

/// Measures per system, as actually engraved: the median over all systems
/// except the last (which is short by definition — it holds the remainder).
///
/// [measureLine] is `EngravedScore.measureLine`: per measure index, its system
/// line index. Returns 0 when there is nothing to measure.
int measuresPerLineOf(List<int> measureLine) {
  if (measureLine.isEmpty) return 0;
  final perLine = <int, int>{};
  for (final line in measureLine) {
    perLine[line] = (perLine[line] ?? 0) + 1;
  }
  final counts = perLine.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  // Drop the final (partial) system, unless it's all we have.
  final usable = counts.length > 1
      ? [for (final e in counts.take(counts.length - 1)) e.value]
      : [counts.first.value];
  usable.sort();
  return usable[usable.length ~/ 2];
}

/// Average engraved width of one measure in MEI units — the scale- and
/// width-invariant calibration constant. Returns 0 when uncalibratable.
double unitsPerMeasureFrom({
  required int pageWidthUnits,
  required int measuresPerLine,
}) {
  if (measuresPerLine <= 0 || pageWidthUnits <= 0) return 0;
  return pageWidthUnits / measuresPerLine;
}

/// The Verovio `scale` that fits about [n] measures across [widthPx], given the
/// piece's [unitsPerMeasure]. Inverts `pageWidth = widthPx * 100 / scale` for
/// `pageWidth = n * unitsPerMeasure * `[staffFitSlack], then clamps to
/// [staffScaleMin]..[staffScaleMax].
///
/// Monotonically decreasing in [n]: fewer measures per line ⇒ larger scale ⇒
/// bigger notes.
double scaleFor({
  required double widthPx,
  required double unitsPerMeasure,
  required int n,
}) {
  if (widthPx <= 0 || unitsPerMeasure <= 0 || n <= 0) return staffScaleProbe;
  final raw = widthPx * 100 / (n * unitsPerMeasure * staffFitSlack);
  return raw.clamp(staffScaleMin, staffScaleMax);
}

/// Predicted rendered height in logical pixels for a [n]-measures-per-line
/// layout.
///
/// [systemHeightPx] is a system's on-screen height as measured on the probe
/// engrave (`EngravedScore.systemHeightViewBox`), which is in **pixels at
/// [measuredAtScale]** — not MEI units, and not scale-invariant. Converting
/// therefore means multiplying by the scale *ratio*: a system drawn at scale 80
/// is twice as tall as the same system at 40.
///
/// Both effects push the same way as [n] shrinks — taller systems AND more of
/// them — so the height falls off quickly as [n] grows.
double predictedHeightPx({
  required double widthPx,
  required double unitsPerMeasure,
  required double systemHeightPx,
  required int measureCount,
  required int n,
  double measuredAtScale = staffScaleProbe,
}) {
  if (measureCount <= 0 || systemHeightPx <= 0 || measuredAtScale <= 0) return 0;
  final lines = (measureCount / n).ceil();
  final scale = scaleFor(widthPx: widthPx, unitsPerMeasure: unitsPerMeasure, n: n);
  return lines * systemHeightPx * (scale / measuredAtScale);
}

/// The default measures-per-line for a piece in a given viewport.
///
/// Prefers the **smallest** count (largest notes) whose whole-piece layout still
/// fits within [staffAutoFillFraction] of [viewportHeightPx] — so a short tune
/// fills the screen with big notes and no scrolling. A piece too long for any
/// count to fit falls back to [measuresPerLineForWidth]: scrolling is
/// unavoidable, so pick a stable size from the screen width instead of shrinking
/// the notes to cram the piece in.
int autoMeasuresPerLine({
  required double widthPx,
  required double viewportHeightPx,
  required double unitsPerMeasure,
  required double systemHeightPx,
  required int measureCount,
  double measuredAtScale = staffScaleProbe,
}) {
  if (widthPx <= 0 ||
      viewportHeightPx <= 0 ||
      unitsPerMeasure <= 0 ||
      systemHeightPx <= 0 ||
      measureCount <= 0) {
    return measuresPerLineForWidth(widthPx);
  }
  final budget = viewportHeightPx * staffAutoFillFraction;
  for (var n = measuresPerLineMin; n <= measuresPerLineMax; n++) {
    final h = predictedHeightPx(
      widthPx: widthPx,
      unitsPerMeasure: unitsPerMeasure,
      systemHeightPx: systemHeightPx,
      measureCount: measureCount,
      n: n,
      measuredAtScale: measuredAtScale,
    );
    if (h <= budget) return n;
  }
  return measuresPerLineForWidth(widthPx);
}

/// Measures per line for a piece too long to fit on one screen, chosen from the
/// viewport width alone. Mirrors `measuresPerRowForWidth` in
/// `models/piece_layout.dart` (which does the same job for the jianpu/fingering
/// views), with an extra step for iPad portrait.
int measuresPerLineForWidth(double widthPx) {
  if (widthPx >= 1000) return 4; // iPad landscape / desktop
  if (widthPx >= 700) return 3; // iPad portrait
  return 2; // phone
}

/// Verovio `pageHeight` (MEI units) big enough to hold the whole score on page
/// one.
///
/// This matters: the engraver only ever renders page 1, so anything past the
/// page bottom is silently dropped, and `adjustPageHeight` then crops the slack —
/// so over-provisioning is free but under-provisioning loses music.
///
/// Note that the page's *capacity in systems* is scale-invariant: zooming in
/// shrinks the page width in MEI units but leaves both the page height and a
/// system's height in units alone. So the long-standing 60000 floor holds a great
/// many systems at any zoom and this rarely binds — it is insurance for a
/// pathologically long piece at a low measures-per-line, not a routine
/// adjustment.
///
/// [systemHeightPx] is in pixels at [measuredAtScale] (see [predictedHeightPx]),
/// hence the `* 100 / scale` conversion into MEI units.
int pageHeightUnitsFor({
  required int measureCount,
  required int measuresPerLine,
  required double systemHeightPx,
  double measuredAtScale = staffScaleProbe,
}) {
  const floor = 60000; // the pre-zoom fixed value, kept as the minimum
  const ceiling = 2000000;
  if (measureCount <= 0 ||
      measuresPerLine <= 0 ||
      systemHeightPx <= 0 ||
      measuredAtScale <= 0) {
    return floor;
  }
  final lines = (measureCount / measuresPerLine).ceil();
  final systemHeightUnits = systemHeightPx * 100 / measuredAtScale;
  // 1.5x headroom absorbs per-system slack (chord symbols, high/low ledger
  // lines, the inter-system gap) that the average smooths away.
  final needed = (lines * systemHeightUnits * 1.5).ceil();
  return needed.clamp(floor, ceiling);
}

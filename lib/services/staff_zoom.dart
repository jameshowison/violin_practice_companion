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

import 'dart:math' as math;
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

/// Bounds on the measures-per-line target the sizes resolve to (see
/// [measuresPerLineForSize] and [autoMeasuresPerLine]).
const int measuresPerLineMin = 1;
const int measuresPerLineMax = 8;

/// Fraction of the viewport Fit aims to fill, leaving the rest as breathing
/// room. Only applies when the whole piece fits — see [autoMeasuresPerLine].
///
/// 0.75 until 2026-11-18, which partly allowed for the play tray over the
/// bottom of the score. The tray hides itself a few seconds after a piece
/// opens, so that room was empty most of the time: on Lightly Row it was the
/// whole difference between 3 bars a line and 4 (the 3-bar layout is 81% of
/// the viewport). The note-spacing squeeze ([fitSpacingLinear]) closes most of
/// the rest of any gap.
const double staffAutoFillFraction = 0.9;

// ── The floor: how small the auto-fit is allowed to make the notes ───────────
//
// [autoMeasuresPerLine] pushes measures-per-line UP to get the whole piece onto
// one screen, and because the two are one knob, every step up shrinks the notes.
// This is where that stops.
//
// The limit is a PHYSICAL size — millimetres of staff — not a pixel count. What
// matters is whether the notes read at practice distance, and a logical pixel is
// not the same physical size on a phone as on a tablet: iOS points are ~153/inch
// on a 3x iPhone but ~132/inch on a 2x iPad, so identical logical notes come out
// ~16% bigger on the iPad. Flooring in pixels would silently make that
// difference the policy; flooring in millimetres states it.
//
// Flutter cannot report a real display DPI (`devicePixelRatio` is the
// logical→device pixel ratio, not pixels per inch), so the conversion uses the
// nominal figure for each device class, chosen by the screen's shortest side.
// That is orientation-invariant, unlike the render width — a phone in landscape
// is wider than an iPad in portrait.

/// Logical pixels per inch, nominal, phone class: a 3x iPhone is ~460 ppi ÷ 3.
/// (A 2x iPhone is 326 ÷ 2 = 163, so on one of those the floor comes out ~6%
/// smaller in millimetres than asked for. Within the noise of a preference that
/// was set by eye.)
const double phonePtPerInch = 153;

/// Logical pixels per inch, nominal, tablet class and up: an iPad is 264 ÷ 2.
/// Also used for desktop/web, where the true figure is lower still (a large
/// monitor is nearer 110), so the floor errs toward bigger notes there.
const double tabletPtPerInch = 132;

/// Shortest-side breakpoint between the two classes — the conventional Flutter
/// tablet test. iPhone 17 is 402pt on its short edge, iPad Pro 11 is 834pt.
const double tabletShortestSidePx = 600;

/// Height of a five-line staff in MEI units: four spaces, two units per space,
/// at Verovio's default `unit` of 9. Rendered pixels are `units × scale / 100`,
/// so **staff height px = 0.72 × scale** — the bridge from a millimetre floor to
/// a `scale` floor.
///
/// Verified by measurement: Happy Farmer engraved at `scale` 25.4 on `dev-iphone`
/// (portrait) came out with 18.3pt between the outer staff lines.
const double staffHeightUnits = 72;

const double _mmPerInch = 25.4;

/// Smallest staff height the auto-fit may choose on a phone.
///
/// Calibrated, not guessed: this is the size Happy Farmer engraved at on
/// `dev-iphone` before the floor existed (scale 25.4 portrait / 27.2 landscape,
/// i.e. 3.0–3.2mm of staff), which is the smallest the notes should ever get.
/// Set a shade under the measured value so the reference piece stays comfortably
/// on the legal side of its own floor rather than balancing on it.
const double minStaffHeightMmPhone = 2.9;

/// Smallest staff height the auto-fit may choose on a tablet — deliberately
/// larger than [minStaffHeightMmPhone], because an iPad is read from a music
/// stand rather than held at arm's length. ~20% more staff.
///
/// Note this lands at almost the same *logical* scale as the phone floor: the
/// iPad's lower point density means a bigger physical staff costs barely any more
/// points. The difference is real all the same — it's just physical, which is
/// the thing being specified.
const double minStaffHeightMmTablet = 3.5;

/// The smallest Verovio `scale` [autoMeasuresPerLine] may resolve to, for a
/// screen whose shortest side is [shortestSidePx].
///
/// Distinct from [staffScaleMin], which is a hard clamp applied to *every* solve
/// including an explicit slider setting. This one governs only the automatic
/// default: the user can still ask for smaller by hand.
double minStaffScaleFor(double shortestSidePx) {
  final tablet = shortestSidePx >= tabletShortestSidePx;
  final mm = tablet ? minStaffHeightMmTablet : minStaffHeightMmPhone;
  final ptPerInch = tablet ? tabletPtPerInch : phonePtPerInch;
  // staffHeightPx = staffHeightUnits * scale / 100, so
  // scale = staffHeightPx * 100 / staffHeightUnits.
  return mm / _mmPerInch * ptPerInch * 100 / staffHeightUnits;
}

// ── The size control: Fit, Small, Medium, Large ──────────────────────────────
//
// What the reader picks from the piece screen's view menu. Small, Medium and
// Large are PHYSICAL staff heights, so a size looks the same in every piece and
// on either orientation; the layout then puts as many bars on a line as fit at
// that size (rounding the notes up a little so the lines justify). Fit is the
// one size worked out per piece: the whole piece on one screen
// ([autoMeasuresPerLine]), never smaller than Small.

/// How big the staff view draws the notes. Stored per piece.
enum StaffSize {
  fit('Fit whole piece'),
  small('Small'),
  medium('Medium'),
  large('Large');

  const StaffSize(this.label);

  /// What the size control calls it.
  final String label;
}

/// Staff height in millimetres for each fixed size, phone class. Small is the
/// legibility floor the auto-fit has always stopped at ([minStaffHeightMmPhone]);
/// Medium and Large step up by about 40% each, which on an SE takes Lightly Row
/// from 4 bars a line to 3 and then 2.
const double mediumStaffHeightMmPhone = 4.0;
const double largeStaffHeightMmPhone = 5.5;

/// The same, tablet class: each about 20% bigger than the phone's, as the floor
/// is, because an iPad is read from a music stand.
const double mediumStaffHeightMmTablet = 5.0;
const double largeStaffHeightMmTablet = 7.0;

/// The smallest Verovio `scale` the notes may be drawn at for [size] on a
/// screen whose shortest side is [shortestSidePx]. For [StaffSize.fit] that is
/// Small's, the floor Fit never goes below.
double staffScaleForSize(StaffSize size, double shortestSidePx) {
  final tablet = shortestSidePx >= tabletShortestSidePx;
  final mm = switch (size) {
    StaffSize.fit || StaffSize.small =>
      tablet ? minStaffHeightMmTablet : minStaffHeightMmPhone,
    StaffSize.medium =>
      tablet ? mediumStaffHeightMmTablet : mediumStaffHeightMmPhone,
    StaffSize.large =>
      tablet ? largeStaffHeightMmTablet : largeStaffHeightMmPhone,
  };
  final ptPerInch = tablet ? tabletPtPerInch : phonePtPerInch;
  return mm / _mmPerInch * ptPerInch * 100 / staffHeightUnits;
}

/// Measures per line for a FIXED [size] (not [StaffSize.fit], which needs the
/// viewport — see [autoMeasuresPerLine]): the most bars that fit across
/// [widthPx] with notes at least that size.
int measuresPerLineForSize({
  required StaffSize size,
  required double widthPx,
  required double unitsPerMeasure,
  required double shortestSidePx,
}) =>
    maxMeasuresPerLineFor(
      widthPx: widthPx,
      unitsPerMeasure: unitsPerMeasure,
      shortestSidePx: shortestSidePx,
      minScale: staffScaleForSize(size, shortestSidePx),
    );

// ── Note spacing: the size control's second lever ────────────────────────────
//
// Verovio's `spacingLinear` sets how much room a note gets for its length.
// Lower packs the notes closer, so a bar is narrower and a line of the same
// bars engraves at a bigger scale. Measured headlessly on Lightly Row: a
// 3-bar line is 86% as wide at 0.2 and 72% at 0.15, and the whole piece
// stops shrinking at about half width (the glyphs touch). `spacingNonLinear`
// is left alone: lowering it mostly takes room from long notes, so half notes
// stop looking long, which is the wrong trade for beginners reading rhythm.

/// Verovio's own default.
const double spacingLinearDefault = 0.25;

/// The tightest Fit may squeeze to, and what Small uses.
const double spacingLinearMin = 0.15;

/// The widest Fit may loosen to, to bring a layout one step too big back onto
/// the screen ([fitSpacingLinear]). Airier than the default, which reads fine.
const double spacingLinearMax = 0.3;

/// The tightest any size goes in the annotated view, whose fingering chips and
/// note names need room across the line too.
const double spacingLinearMinAnnotated = 0.2;

/// The spacing a fixed size engraves at: Small is for seeing more of the
/// piece, so it packs tight and fits more bars at the same note size; Large is
/// for reading closely and keeps the default room. Fit starts from the
/// default and squeezes ([fitSpacingLinear]).
///
/// The annotated view keeps the same three steps inside its own floor
/// ([spacingLinearMinAnnotated]), so Small and Medium stay distinct there.
double spacingLinearForSize(StaffSize size, {bool annotated = false}) =>
    switch ((size, annotated)) {
      (StaffSize.small, false) => spacingLinearMin,
      (StaffSize.small, true) => spacingLinearMinAnnotated,
      (StaffSize.medium, false) => 0.2,
      (StaffSize.medium, true) => 0.225,
      (StaffSize.fit || StaffSize.large, _) => spacingLinearDefault,
    };

/// The spacing at which one of Fit's layouts fills [budgetPx] of height, or
/// null when no spacing in range brings it there.
///
/// Height grows with scale, and scale with the inverse of the line's natural
/// width, so the width wanted is `widthAtDefault × predictedHeightPx /
/// budgetPx`. The spacing that gives it is read off a straight line through
/// the piece's measured natural widths at [spacingLinearDefault] and at
/// [minSpacing] ([naturalWidthAtSpacing]), which is close to linear over that
/// range (Lightly Row: 100%, 86%, 72%).
///
/// It works both ways. A layout that leaves room is squeezed (tighter
/// spacing, bigger notes), down to [minSpacing], below which it simply stays
/// a little short. A layout one step too big for the screen is loosened
/// (wider spacing, smaller notes) to come back inside it, up to [maxSpacing];
/// past that it is unreachable, and null says so. Fit tries both its
/// current layout and the next bigger one, and keeps whichever ends up with
/// the bigger notes.
///
/// Rounded UP to a step of 0.005, which errs toward a little more width and
/// so a little less height, never a score that runs past the budget, and
/// keeps nearby requests on one engrave-cache entry. Returns
/// [spacingLinearDefault] when nothing was measured.
double? fitSpacingLinear({
  required double predictedHeightPx,
  required double budgetPx,
  required double widthAtDefault,
  required double widthAtMin,
  double minSpacing = spacingLinearMin,
  double maxSpacing = spacingLinearMax,
}) {
  if (predictedHeightPx <= 0 ||
      budgetPx <= 0 ||
      widthAtDefault <= 0 ||
      widthAtMin <= 0 ||
      widthAtMin >= widthAtDefault) {
    return spacingLinearDefault;
  }
  final want = widthAtDefault * predictedHeightPx / budgetPx;
  final t = (widthAtDefault - want) / (widthAtDefault - widthAtMin);
  final s = spacingLinearDefault - t * (spacingLinearDefault - minSpacing);
  if (s > maxSpacing + 1e-9) return null;
  return ((s * 200).ceil() / 200).clamp(minSpacing, maxSpacing);
}

/// The piece's natural width at [spacing], on the straight line
/// [fitSpacingLinear] reads its spacing off.
double naturalWidthAtSpacing(
  double spacing, {
  required double widthAtDefault,
  required double widthAtMin,
  double minSpacing = spacingLinearMin,
}) =>
    widthAtDefault -
    (spacingLinearDefault - spacing) /
        (spacingLinearDefault - minSpacing) *
        (widthAtDefault - widthAtMin);

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
  return (16 * staffSpacing * staffSpacing)
      .round()
      .clamp(0, verovioSpacingSystemMax);
}

/// Verovio's own `spacingSystem` default — 4, established by the measurement in
/// [verovioSpacingSystemFor]. Also the gap the one-lane layout was tuned against,
/// so it's the baseline the annotation reserve sits on top of.
const int verovioSpacingSystemDefault = 4;

/// Verovio's default `pageMarginTop` in MEI units, passed explicitly so the
/// engrave states its own margin rather than inheriting one.
/// Verified by measurement: passing 50 back reproduces the 31.9px above the first
/// system that the un-set option gave, so a 1-lane engrave is unchanged.
const int verovioPageMarginTopDefault = 50;

/// The largest `pageMarginTop` Verovio actually honours. Measured: 500 works,
/// 510 and every value above it silently reverts to the layout you get at the
/// default — no warning, no error, just the margin quietly gone. Worth a clamp,
/// because a silent revert here reads as "the reserve doesn't work".
const int verovioPageMarginTopMax = 500;

/// The ceiling the staff-spacing preference and the annotation reserve share.
/// Also Verovio's own maximum for `spacingSystem` (0..48 in 6.2): above it the
/// option is rejected with a logged error and the previous value stays, so the
/// clamp is required, not just tidy. The gap it buys is already most of a
/// system's height at 48.
const int verovioSpacingSystemMax = 48;

// ── Asking Verovio for the annotation stack's room ───────────────────────────
//
// The annotations are engraved (see [VerovioEngraver.stripAnnotationGlyphs]), so
// Verovio reserves and reports their row — but it reserves LESS than the two
// drawn rows want, and the app cannot make a row taller than the room above it.
// This is where the extra room is bought.
//
// ## The two prices, measured
//
// One `spacingSystem` unit is worth **exactly half a staff space** of room
// between systems. Not approximately: across all fifteen fixtures, in both
// device orientations, at Verovio `scale` 40 and 80, every one-unit step moved
// the room from the previous system's ink to the fingering register by
// 0.50 ± 0.01 spaces. (Which is what `spacingSystem` means — Verovio's `unit` is
// half a staff space — but the app had no measurement of it, and the *usable*
// room is not obviously the same thing as the nominal gap.) Below 2 units the
// yield stops: 0, 1 and 2 all engrave identically, so Verovio has a floor of its
// own down there.
//
// One `pageMarginTop` unit is worth **1/18 of a staff space** (0.0556, measured
// over 50..500 on five pieces, dead linear). Nine times weaker than a spacing
// unit, so the two knobs need separate constants — reserving the same number of
// units in both would over-reserve the gap by 9×.
//
// ## Why line 0 needs the second knob at all
//
// [_annotationBudget] takes the MINIMUM room over every system, and system 0 has
// no system above it — its room is the page's top margin. So without the margin
// term the first line becomes the binding minimum (3.92 spaces, measured) and
// drags the whole score's rows down to it, however generous the inter-system gap
// is. The margin is a one-off, though: it grows the page once, not once per
// system, so it costs essentially nothing.
//
// ## Why this is not the reserve that failed
//
// A previous version of this file asked Verovio for lane room too, and it was
// deleted (`3e7796a`). Three things were wrong with it, and none of them applies
// here:
//
// 1. **It was a fraction of a variable.** The appetite was expressed as a share
//    of `contentHeightViewBox` — the system's whole ink extent — so a tune with
//    a wide leap in it asked for more room than the same tune transposed into a
//    smaller range. The requirement is now a fixed number of STAFF SPACES,
//    which is what the type is sized in, so it is one number for every piece at
//    every zoom.
// 2. **It was a floor, not an addend.** `verovioSpacingSystemEngraved` took
//    `max(preference + reserve, default + reserve)`, so every staff-spacing
//    below the default engraved the same gap and the bottom half of that slider
//    did nothing. [annotationReserveFor] just ADDS, so the slider keeps its
//    full range: at the minimum the user gets a tight page and the rows shrink
//    to fit it, which is a legitimate thing to ask for.
// 3. **It was keyed on which lanes were being drawn**, so toggling chord
//    symbols changed an engrave input and re-flowed the page. The reserve is now
//    keyed on what the SCORE carries ([scoreReservesAnnotationRoom]), which no
//    display toggle can change.
//
// ## What it costs the auto-fit, measured
//
// Gap is not free: it inflates `systemHeightPx`, which is what
// [autoMeasuresPerLine] budgets against, and that budget has a CLIFF rather than
// a slope — a piece that no longer fits doesn't shrink a little, it jumps
// straight to [maxMeasuresPerLineFor]. That is what killed the old reserve's
// credibility, so this one was measured against it before being chosen.
//
// Engraved every bundled piece in `assets/library` at both dev-iphone viewports
// (358×686 portrait, 706×282 landscape) and re-ran the auto-fit on the resulting
// probe geometry. At 3.5 spaces of reserve:
//
// * **Portrait: nothing moves at all**, 15 pieces out of 15. Twelve of them are
//   pinned at the note-size ceiling, where the height budget never gets asked;
//   the other three keep 24-28% of headroom.
// * **Landscape: two of 15 move, by one notch each** — Lightly Row and The
//   Wellerman go from 6 measures a line to 7, which is their ceiling. Lightly Row
//   had 2% of headroom before this change and The Wellerman 10%, so they were
//   already balancing on the edge; a bar of chord text either way would have
//   tipped them.
// * The three cases pinned in `staff_zoom_test.dart` ("Happy Farmer 3-per-line
//   portrait", "Happy Farmer 7-per-line landscape", "Gavotte stops at 6") are all
//   ceiling-bound, so **none of them can move**, at any reserve.
//
// 4.0 spaces would take O Come Little Children from 4 measures a line to 5 in
// portrait, so that was the ceiling on any constant. It stops being the relevant
// number once the reserve is measured per score — but the CLIFF it describes
// does not, which is why [annotationReserveFor]'s output has to be fed back into
// `systemHeightPx` before the auto-fit reads it.
//
// And note what the cliff costs when it does fire: it re-solves `scale`, so the
// notes resize along with the labels. Annotation size tracking note size is the
// one coupling that IS wanted.

/// Staff spaces of inter-system room one `spacingSystem` unit buys. Measured;
/// see the section note above.
const double spacesPerSpacingSystemUnit = 0.5;

/// Staff spaces of room above the first system one `pageMarginTop` unit buys.
/// Measured; nine times weaker than [spacesPerSpacingSystemUnit].
const double spacesPerPageMarginTopUnit = 1 / 18;

// The reserve is DERIVED, not chosen. It used to be a constant here — 3.5 staff
// spaces, then 1.5 once the measurement was fixed — sized against the worst case
// in `assets/library`. See [annotationReserveFor], which measures the shortfall
// off the calibration probe instead.
//
// Be honest about what that bought, because it is less than it sounds. The probe
// engraves at [staffScaleProbe] with no measures-per-line target, which is the
// TIGHTEST layout the score will ever have — so the shortfall it measures is
// close to the worst case a constant would have been sized against anyway.
// Measured: Old Joe Clark derives 3 spacing units and 32 margin units on an iPad
// in portrait at three measures a line, and the SAME 3 and 32 on a phone in
// landscape at eight, where the real layout is roomier. The constant it replaced
// was 3 and 36. So this is not a height win on the library; it is a correctness
// win for scores the library does not contain, and one less magic number.
//
// The lever that would reclaim height is the other direction: measure the room
// on the REAL engrave and re-engrave with a SMALLER reserve when the layout
// turns out to have room to spare. That costs a round trip per zoom level and is
// not done here.
//
// Known limitation while we are being honest: the reserve is derived once per
// calibration, and the calibration key is (xml, tabMode, spacingUnits, locked,
// showNoteNames) with no width term — so rotating the device does not re-derive it. Measured as
// immaterial (portrait and landscape derived identically on both simulators),
// which is why it is documented rather than fixed with an extra engrave.

/// The reserve to ask Verovio for, derived from a probe engrave rather than
/// assumed.
///
/// Both rooms come in as staff spaces, which is the scale-invariant currency:
/// the probe runs at [staffScaleProbe] and the real engrave at whatever the zoom
/// solved for, and a room measured in spaces transfers between them. Pass
/// `double.infinity` for a room that does not exist — a score with no engraved
/// annotation on that system draws nothing there and needs nothing — and the
/// shortfall comes out negative, so the reserve comes out zero.
///
/// The two are priced separately because Verovio charges them separately: a
/// `spacingSystem` unit buys half a space in every gap on the page, a
/// `pageMarginTop` unit an eighteenth of one, once, above system 0. Hence nine
/// times as many units for the same room, and hence the clamp — past
/// [verovioPageMarginTopMax] Verovio silently ignores the option, so a reserve
/// that would exceed it has to be capped rather than allowed to vanish.
({int spacingUnits, int pageMarginTopUnits}) annotationReserveFor({
  required double interSystemRoomSpaces,
  required double firstSystemRoomSpaces,
  required double wantSpaces,
}) {
  int unitsFor(double shortfallSpaces, double spacesPerUnit, int maxUnits) {
    if (!shortfallSpaces.isFinite || shortfallSpaces <= 0) return 0;
    return (shortfallSpaces / spacesPerUnit).ceil().clamp(0, maxUnits);
  }

  return (
    spacingUnits: unitsFor(
      wantSpaces - interSystemRoomSpaces,
      spacesPerSpacingSystemUnit,
      verovioSpacingSystemMax,
    ),
    // Headroom, not the absolute maximum: this reserve is ADDED to Verovio's
    // default, and it is the sum that has to stay under the cap.
    pageMarginTopUnits: unitsFor(
      wantSpaces - firstSystemRoomSpaces,
      spacesPerPageMarginTopUnit,
      verovioPageMarginTopMax - verovioPageMarginTopDefault,
    ),
  );
}

/// Whether the score in [musicXml] carries the engraved annotations the app
/// draws its own rows on, and therefore needs the room reserved.
///
/// A property of the SCORE, not of any display preference — which is the whole
/// point. The annotated view injects `<fingering>` placeholders; under the
/// native renderer every view keeps `<harmony>` unless the instrument has no
/// chords at all (`_stripHarmonyFor` in `providers.dart`), and the tab view
/// carries no `<fingering>`. So this asks exactly the right question of each of
/// the three, and no toggle on the piece screen changes the answer — a
/// chord-symbol switch stays a repaint.
bool scoreReservesAnnotationRoom(String musicXml) =>
    musicXml.contains('<fingering') || musicXml.contains('<harmony');

// ── Annotation type size ─────────────────────────────────────────────────────
//
// One rule, for every annotation lane: **a label reads slightly larger than the
// notehead it describes.** Which means the yardstick is the staff space (a
// notehead is one space tall), not the lane it happens to be drawn in.
//
// The lane is the wrong yardstick twice over. Its height is a fraction of
// `EngravedScore.contentHeightViewBox` — the system's whole ink extent — so it
// grows with the melody's RANGE: two pieces at identical note size get different
// label sizes because one of them has a wide leap in it. And the lane's height
// then passes through a chain of shrink factors before any type comes out of it.
// Measured on Will The Circle Be Unbroken at `scale` 34 (staff space 6.1px): a
// 15.0px channel became an 11.0px chip zone (×0.22/0.30), an 8.8px chip (×0.80)
// and a 5.8px font (×0.66) — 39% of the reserved lane, for a digit whose cap
// height came to two thirds of a notehead's. The white space was all inside the
// lane, so this is fixed by spending the lane better, not by asking for more of
// it (`squeeze` was already 0.94 — there was no more to have).

/// Fraction of a font's point size that a capital or digit actually inks. 0.71
/// for Roboto (Flutter's default on Android/iOS-fallback) and within a point or
/// two of it for the system faces, which is well inside the tolerance of "looks
/// slightly bigger than a notehead".
const double labelCapHeightRatio = 0.71;

/// How tall an annotation digit should ink, in staff spaces. A notehead is one
/// space, so 1.2 is the "slightly larger" — big enough to win the comparison at
/// a glance, small enough that the row still reads as annotation over music
/// rather than as a second voice competing with it.
const double annotationCapHeightSpaces = 1.2;

/// The point size an annotation label wants on a staff whose space is
/// [staffSpacePx]: the size at which its cap height is
/// [annotationCapHeightSpaces] spaces.
///
/// Scale-invariant by construction — the staff space is itself proportional to
/// the engraving scale — so a label holds its size relative to the notes at every
/// zoom level, which is the property the measures-per-line slider must not be
/// able to break.
double annotationFontSizeFor(double staffSpacePx) => staffSpacePx <= 0
    ? 0
    : staffSpacePx * annotationCapHeightSpaces / labelCapHeightRatio;

/// How tall the chord bar and the fingering channel are, given the room the
/// tightest system offers. ONE answer for the whole score.
///
/// Uniform by construction, and that is the point: a register whose thickness
/// changes from line to line does not read as a register. Sizing each system to
/// its own room produced exactly that — measured on Old Joe Clark, bar heights of
/// 23.0, 5.3, 9.3, 9.3 and 22.2px down the same page, so the bar looked present on
/// the first and last systems and absent in the middle.
///
/// The two rows want `font / labelShare` and `font / typeShare` between them, plus
/// a hairline gap — 2.56 + 3.16 + 0.31 = 6.03 staff spaces. Verovio's own
/// reservation at its default spacing is a good deal less than that (1.84 to 4.06
/// across the fixtures), which is why the engrave now ASKS for the difference —
/// see [annotationReserveFor]. This shrink is the net underneath that: it catches
/// a score tighter than any measured one, and the bottom half of the
/// staff-spacing slider, where the user has explicitly asked for a tight page.
/// Both rows scale down together, in proportion, rather than one absorbing the
/// whole shortfall.
///
/// [withChordBar] / [withFingeringRow] say which rows this score will actually
/// draw, and the appetite counts only those. Necessary, not tidiness: most of the
/// library carries no `<harmony>`, so `harmRegister` is null and no chord bar is
/// ever painted — charging those scores for 2.87 spaces of bar they will not draw
/// meant the fingering row alone had to fit in half the room it needed, and it
/// was the reserve that would have had to pay for the difference (9 units instead
/// of 7, i.e. a system a quarter taller, for space nothing occupies). The tab
/// view is the mirror image: `<harmony>` but no `<fingering>`, so a bar and no
/// channel.
///
/// [budgetPx] is the room the tightest system has between the previous system's
/// ink and its own annotation register. [minShare] floors the shrink so a
/// pathologically tight score gets small labels rather than invisible ones; past
/// that point the rows would rather overlap the system above than disappear.
({double barHeight, double channelHeight, double gap}) annotationStackFor({
  required double budgetPx,
  required double staffSpacePx,
  required double labelShare,
  required double typeShare,
  bool withChordBar = true,
  bool withFingeringRow = true,
  double gapShare = 0.12,
  double minShare = 0.55,
}) {
  final font = annotationFontSizeFor(staffSpacePx);
  if (font <= 0 || labelShare <= 0 || typeShare <= 0) {
    return (barHeight: 0, channelHeight: 0, gap: 0);
  }
  final bar = withChordBar ? font / labelShare : 0.0;
  final channel = withFingeringRow ? font / typeShare : 0.0;
  // The gap exists to keep the bar off the row below it, so it is only wanted
  // when both are there.
  final gap = withChordBar && withFingeringRow ? bar * gapShare : 0.0;
  final want = bar + channel + gap;
  if (want <= 0) return (barHeight: 0, channelHeight: 0, gap: 0);
  final k = budgetPx <= 0 || budgetPx >= want
      ? 1.0
      : math.max(minShare, budgetPx / want);
  return (barHeight: bar * k, channelHeight: channel * k, gap: gap * k);
}

/// [annotationFontSizeFor], capped to what a [laneHeightPx]-tall lane can host
/// when [laneTypeShare] of its height goes to type.
///
/// The want is a target, the channel is a hard ceiling: a label that overflowed
/// would land on the notes (or on the chord bar above), which is worse than a
/// label that is a little small.
///
/// Worth keeping now that the channel is MEASURED rather than derived from a
/// fraction — the clamp used to fire routinely, because `laneSqueeze` scaled every
/// lane in the score by its tightest gap, and that is how the fingering row ended
/// up at a 5px font. Against [annotationStackFor] it only fires where the room
/// genuinely is not there, and then it degrades quietly instead of colliding.
double annotationFontSizeIn({
  required double staffSpacePx,
  required double laneHeightPx,
  double laneTypeShare = 0.78,
}) {
  final want = annotationFontSizeFor(staffSpacePx);
  if (laneHeightPx <= 0) return want;
  return math.min(want, laneHeightPx * laneTypeShare);
}

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
  List<Rect> measureRects,
) {
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
        top: l == 0
            ? contentTop[0]
            : (contentBottom[l - 1] + contentTop[l]) / 2,
        bottom: l == n - 1
            ? contentBottom[n - 1]
            : (contentBottom[l] + contentTop[l + 1]) / 2,
      ),
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
  List<Rect> measureRects,
  List<int> measureLine,
) {
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
      (top: tops[l] ?? 0.0, bottom: bottoms[l] ?? 0.0),
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
  final counts = perLine.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  // Drop the final (partial) system, unless it's all we have.
  final usable = counts.length > 1
      ? [for (final e in counts.take(counts.length - 1)) e.value]
      : [counts.first.value];
  usable.sort();
  return usable[usable.length ~/ 2];
}

/// Average engraved width of one measure in MEI units — the scale- and
/// width-invariant calibration constant. Returns 0 when uncalibratable.
///
/// This is an UPPER bound, not a measurement: an engrave can only say "N
/// measures did fit in W units", and justification stretched them to fill that
/// width, so the natural minimum is somewhere at or below `W / N`. The error is
/// up to half a measure, i.e. `1 / 2N` — tolerable at N = 5, and 25% at N = 2.
/// Combine successive observations with [tighterUnitsPerMeasure] rather than
/// trusting any single one.
double unitsPerMeasureFrom({
  required int pageWidthUnits,
  required int measuresPerLine,
}) {
  if (measuresPerLine <= 0 || pageWidthUnits <= 0) return 0;
  return pageWidthUnits / measuresPerLine;
}

/// Folds a fresh [unitsPerMeasureFrom] observation into a running estimate by
/// keeping the **smaller** — every observation is an upper bound, so the least
/// one is the best one. 0 means "no estimate yet" on either side.
///
/// Monotone by construction, which is what makes it safe to feed back into the
/// solve: a later engrave that happens to pack loosely cannot undo an earlier
/// correction, so the sequence settles instead of oscillating.
///
/// Why this matters, measured on Old Joe Clark at 358pt wide: the probe fit 2
/// bars in 895 units (447.5), the solve therefore asked for 3 bars a line at
/// `scale` 25.4 — and Verovio packed 4 bars into that page's 1410 units (352.5).
/// Notes sized for 3 bars, 4 to a line, and the score used 43% of the screen.
/// Tightening to 352.5 re-solves the same target at `scale` 32.2: 3 bars a line
/// as asked, notes a quarter bigger, 66% of the screen.
double tighterUnitsPerMeasure(double current, double observed) {
  if (observed <= 0) return current;
  if (current <= 0) return observed;
  return math.min(current, observed);
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
  if (measureCount <= 0 || systemHeightPx <= 0 || measuredAtScale <= 0)
    return 0;
  final lines = (measureCount / n).ceil();
  final scale = scaleFor(
    widthPx: widthPx,
    unitsPerMeasure: unitsPerMeasure,
    n: n,
  );
  return lines * systemHeightPx * (scale / measuredAtScale);
}

/// The most measures per line that keeps the notes at or above the device's
/// minimum physical size — the ceiling on [autoMeasuresPerLine]'s search.
///
/// The inverse of [scaleFor], so `scaleFor(n: this)` lands on or above
/// [minStaffScaleFor] while `n + 1` would fall below it. Also capped by
/// [measuresPerLineMax], which binds first on a wide tablet — 8 measures across
/// an iPad in landscape still engrave at ~4.5mm of staff.
///
/// The one case where the result is below the floor is a piece dense enough that
/// even ONE measure per line is: [measuresPerLineMin] is the end of the road,
/// there being no smaller count to fall back to.
///
/// Falls back to [measuresPerLineMax] when uncalibrated: no ceiling is better
/// than a wrong one, and the caller has its own degenerate-input path.
int maxMeasuresPerLineFor({
  required double widthPx,
  required double unitsPerMeasure,
  required double shortestSidePx,
  double? minScale,
}) {
  minScale ??= minStaffScaleFor(shortestSidePx);
  if (widthPx <= 0 || unitsPerMeasure <= 0 || minScale <= 0) {
    return measuresPerLineMax;
  }
  final n = widthPx * 100 / (unitsPerMeasure * staffFitSlack * minScale);
  return n.floor().clamp(measuresPerLineMin, measuresPerLineMax);
}

/// The default measures-per-line for a piece in a given viewport: **the whole
/// piece on one screen if that can be had without shrinking the notes past the
/// device's floor, and the floor otherwise.**
///
/// Prefers the **smallest** count (largest notes) whose whole-piece layout fits
/// within [staffAutoFillFraction] of [viewportHeightPx] — so a short tune fills
/// the screen with big notes and no scrolling — and searches upward from there,
/// packing more measures onto each line to get a longer piece in view too.
///
/// The search stops at [maxMeasuresPerLineFor]. That ceiling is the whole point:
/// without it a long piece is crammed in at whatever size it takes, which on a
/// phone measured out at Verovio `scale` 20 for a 32-bar Gavotte — 2.2mm of
/// staff, well past illegible, and still not filling the screen vertically
/// (width justification means the horizontal fit is what sets the size, so the
/// leftover height is unavoidable). Past the ceiling, scrolling a legible score
/// is the better trade, and that is what returning the ceiling gives.
///
/// [shortestSidePx] is the screen's shortest side — the device class, hence the
/// physical floor. It is NOT the render width (which is orientation-dependent).
int autoMeasuresPerLine({
  required double widthPx,
  required double viewportHeightPx,
  required double shortestSidePx,
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
  final ceiling = maxMeasuresPerLineFor(
    widthPx: widthPx,
    unitsPerMeasure: unitsPerMeasure,
    shortestSidePx: shortestSidePx,
  );
  final budget = viewportHeightPx * staffAutoFillFraction;
  for (var n = measuresPerLineMin; n < ceiling; n++) {
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
  return ceiling;
}

/// Measures per line from the viewport width alone — the answer when there is no
/// calibration to reason from: an uncalibrated score in [autoMeasuresPerLine],
/// and the slider's parked position before the first engrave reports back.
///
/// It is deliberately NOT the "piece too long to fit" answer any more; that is
/// [maxMeasuresPerLineFor], which knows the piece and the device's note-size
/// floor. Falling back here used to mean a long piece jumped from 8 measures a
/// line to 2, quadrupling the note size and the scrolling in one step.
///
/// The staff's counterpart to `measuresPerRowForWidth` in
/// `models/piece_layout.dart` (the jianpu/fingering views), but the two are
/// independent and their breakpoints differ: that one gives 4 from 600px and
/// 2 below.
int measuresPerLineForWidth(double widthPx) {
  if (widthPx >= 1000) return 4; // iPad landscape / desktop
  if (widthPx >= 700) return 3; // iPad portrait
  return 2; // phone
}

/// Verovio `pageHeight` (MEI units) for every engrave: its MAXIMUM.
///
/// The engraver only ever renders page 1, so anything past the page bottom
/// spills onto a page that is never drawn; `adjustPageHeight` then crops the
/// slack, so asking for the most Verovio allows costs nothing.
///
/// Verovio 6.2 accepts 100..60000 (the native verovio_flutter 0.3.1 build
/// bundles 6.2.1 with the same option code). A larger value is REJECTED, with
/// only a logged error, and the option keeps whatever it held before — on a
/// fresh toolkit that is the ~A4 default of 2970, one printed page. So never
/// ask for more: an earlier version computed a page "big enough" for long
/// pieces, up to 2000000, and any piece that needed more than 60000 got one A4
/// page of music instead. (Measured headlessly with
/// `tool/verovio/verovio-toolkit-wasm.js`.)
///
/// A system's height in units doesn't change with zoom, so 60000 holds well
/// over a hundred ordinary systems at any zoom. A score that still doesn't fit
/// is logged by [VerovioEngraver] (`[engrave] page overflow`), not clipped
/// silently.
const int verovioPageHeightMax = 60000;

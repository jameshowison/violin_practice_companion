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

/// Slider bounds for the measures-per-line target. Exposed as top-level consts
/// so a test can assert `min < max`: a zero-range [Slider] cannot claim drag
/// gestures and they leak to parent handlers (the settings Drawer's
/// swipe-to-close). See `test/staff_spacing_slider_test.dart`.
const int measuresPerLineMin = 1;
const int measuresPerLineMax = 8;

// ── Orientation ──────────────────────────────────────────────────────────────

/// Which way up the screen is, for the purpose of storing a zoom.
///
/// The zoom preference is per orientation because measures-per-line means a
/// different note size in each: a phone in landscape is roughly twice as wide as
/// in portrait, and the score is engraved to the full width either way, so the
/// same count gives glyphs of very different sizes. One saved value cannot serve
/// both.
///
/// Deliberately NOT Flutter's `Orientation` — this file and [StaffZoomStore] are
/// both plain Dart, and the widget layer converts at the one point where it
/// reads `MediaQuery`.
///
/// Note this is a different question from the phone/tablet split that
/// [minStaffScaleFor] asks, which is orientation-INVARIANT by design (see
/// [tabletShortestSidePx]). Device class sets how small notes may get; this sets
/// which saved number to get it from.
enum StaffOrientation {
  portrait,
  landscape;

  StaffOrientation get other => this == StaffOrientation.portrait
      ? StaffOrientation.landscape
      : StaffOrientation.portrait;
}

// ── Pinch ────────────────────────────────────────────────────────────────────
//
// A pinch has to be expressed in the one unit this app has: measures per line.
// There is no free-floating zoom factor to turn — note size IS `scale`, and
// `scale` is fixed by how many measures have to fit across the viewport.

/// The measures-per-line a pinch of accumulated factor [scale] is asking for,
/// having started from [from].
///
/// Inverse, because the two are one knob: [scaleFor] makes the Verovio `scale`
/// (hence the glyph size) proportional to `1/n`, so notes [scale] times bigger
/// want `n / scale` measures on a line. Pinching OUT therefore packs FEWER
/// measures per line, which is what makes the gesture feel right — the page
/// under the fingers grows.
///
/// Clamped to the same [measuresPerLineMin]..[measuresPerLineMax] the slider
/// uses, so a pinch can't reach a zoom the slider then can't represent.
int pinchTargetMeasuresPerLine({required int from, required double scale}) {
  if (from <= 0 || scale <= 0 || !scale.isFinite) {
    return from.clamp(measuresPerLineMin, measuresPerLineMax);
  }
  return (from / scale).round().clamp(measuresPerLineMin, measuresPerLineMax);
}

/// The range a pinch preview may usefully be drawn over, starting from [from]:
/// the scales beyond which [pinchTargetMeasuresPerLine] stops moving.
///
/// The preview is a plain `Transform.scale` of the already-engraved page, so
/// nothing stops it growing forever — but the release can only deliver a target
/// inside the clamp. Past the ends of this range the picture would be promising
/// a zoom that is not coming, and the layout would visibly spring back on
/// release. Bounding the transform here means what is on screen when the fingers
/// lift is what gets engraved.
///
/// The ends are the factors at which the picture is *exactly* the size the
/// extreme layouts engrave at — `from/min` and `from/max`, the same ratio the
/// widget holds the preview at while it waits for the new score. Stopping at the
/// midpoint where [num.round] flips would be a little easier on the fingers, but
/// it lands the preview on a size no layout has, and at `from == 2` the tie
/// rounds the wrong way and the outermost target becomes unreachable.
///
/// Both ends therefore include 1 (the rest position) for free, since [from] is
/// itself inside the clamp — and the degenerate ends fall out right: at
/// `from == 1` the score is already as large as it goes, so the range is
/// `(…, 1]`, pinch in but not out.
///
/// Reaching an extreme takes a full-range pinch (4× to get from 4 measures a
/// line to 1). That is fine, and normal: each release commits, so a second pinch
/// starts from the new count.
({double min, double max}) pinchScaleLimits(int from) {
  if (from <= 0) return (min: 1, max: 1);
  return (
    min: math.min(1, from / measuresPerLineMax),
    max: math.max(1, from / measuresPerLineMin),
  );
}

/// Fraction of the viewport the auto default aims to fill, leaving the rest as
/// breathing room. Only applies when the whole piece fits — see
/// [autoMeasuresPerLine].
const double staffAutoFillFraction = 0.75;

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
// deleted (`faecd5c`). Three things were wrong with it, and none of them applies
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
//    did nothing. [verovioSpacingSystemForEngrave] just ADDS, so the slider
//    keeps its full range: at the minimum the user gets a tight page and the
//    rows shrink to fit it, which is a legitimate thing to ask for.
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
// Engraved every fixture in `assets/fixtures` at both dev-iphone viewports
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
// portrait. 3.5 is therefore the last free half-space, which is why it is the
// figure — see [annotationRoomSpaces].
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

/// Extra staff spaces of room to ask Verovio for when the score carries
/// annotations the app draws its own rows on.
///
/// **This was 3.5, and most of that was paying for a measurement bug.** The room
/// above a system's annotation register is read as
/// `register - lineContent[l-1].bottom`, and that bottom used to come from the
/// hit map's `measure` boxes, which `verovio_flutter` computes client-side. On
/// the 6-system iPad-portrait layout it came out 2.2 staff spaces deeper than
/// the ink actually goes. So the app believed every system was more cramped than
/// it was, shrank the annotation rows to fit the room it thought it had, and
/// bought the shortfall back here — where it surfaced as a band of white between
/// the systems, which is the thing a reader actually notices.
/// `VerovioEngraver.systemInkBoxes` now takes the extent from Verovio's own
/// `svgBoundingBoxes` output instead; on Old Joe Clark that agreed with the
/// rendered pixels to 0.05 of a space. See that method for what is and is not
/// explained about the old number.
///
/// With the measurement honest, 1.5 is what the shortfall actually is. Measured
/// on Old Joe Clark (18 bars, chord symbols and fingerings, 6 systems, iPad
/// portrait at 3 measures a line):
///
/// | reserve | page height | band above the chord bar | rows          |
/// |---------|-------------|--------------------------|---------------|
/// | 3.5     | 1408 px     | 3.50 spaces              | full size     |
/// | **1.5** | **1244 px** | **1.53 spaces**          | bar at 77%    |
/// | 0       | 1121 px     | 1.53 spaces              | bar at 57%    |
///
/// Read the last two rows together: below 1.5 the reserve stops buying page
/// height and only costs row size, because ~1.5 spaces of that band is
/// Verovio's own inter-system whitespace and no reserve setting reaches it.
/// That is what makes 1.5 the corner rather than a compromise.
///
/// The cost is the chord bar at 77% of its intended height; the fingering row
/// stays full size, both stay legible, and the page is 12% shorter — which on a
/// music stand is fewer scrolls mid-tune. Raise it back toward 3.5 to trade that
/// away again; [annotationStackFor] shrinks the rows to whatever is left either
/// way, so nothing collides at any setting.
const double annotationRoomSpaces = 1.5;

/// The same room for system 0, which is a bigger number for a smaller cost.
///
/// System 0 has no system above it to borrow from — the page's top margin is all
/// it has — and Verovio is stingier there. Measured across the library with
/// Verovio's own boxes, the tightest first system carrying both rows is Old Joe
/// Clark's at 4.22 spaces against the 6.03 it wants, a shortfall of 1.81 where
/// the worst INTER-system shortfall is 1.47.
///
/// Two constants rather than one because the two are paid differently:
/// `spacingSystem` is charged once per gap, so half a space there costs half a
/// space times every system on the page, while `pageMarginTop` is charged once
/// for the whole score. Rounding system 0 up to 2.0 buys it a margin the
/// interior systems could not afford.
const double annotationRoomSpacesFirstSystem = 2.0;

/// `spacingSystem` units that buy [annotationRoomSpaces] between systems — 3.
int get annotationSpacingSystemUnits =>
    (annotationRoomSpaces / spacesPerSpacingSystemUnit).ceil();

/// `pageMarginTop` units that buy [annotationRoomSpacesFirstSystem] above
/// system 0 — 36. Nine times as many units per space; see the section note.
int get annotationPageMarginTopUnits =>
    (annotationRoomSpacesFirstSystem / spacesPerPageMarginTopUnit).ceil();

/// Whether the score in [musicXml] carries the engraved annotations the app
/// draws its own rows on, and therefore needs the room reserved.
///
/// A property of the SCORE, not of any display preference — which is the whole
/// point. The annotated view injects `<fingering>` placeholders and keeps
/// `<harmony>` unconditionally (see `_keepHarmonyForAnnotated`), the plain staff
/// view strips both, and the tab view keeps `<harmony>` alone. So this asks
/// exactly the right question of each of the three, and no toggle the user can
/// reach changes the answer — a chord-symbol switch stays a repaint.
bool scoreReservesAnnotationRoom(String musicXml) =>
    musicXml.contains('<fingering') || musicXml.contains('<harmony');

/// The `spacingSystem` to engrave with: the staff-spacing preference, PLUS the
/// annotation reserve when the score needs one.
///
/// Additive, not floored — see point 2 of the section note above for why that
/// distinction is the whole difference from the version of this that failed.
int verovioSpacingSystemForEngrave(
  double staffSpacing, {
  required bool annotationRoom,
}) => (verovioSpacingSystemFor(staffSpacing) +
        (annotationRoom ? annotationSpacingSystemUnits : 0))
    .clamp(0, 48);

/// The `pageMarginTop` to engrave with: Verovio's default, plus the reserve for
/// system 0's rows when the score needs one. Clamped to
/// [verovioPageMarginTopMax], past which Verovio silently ignores it.
int verovioPageMarginTopForEngrave({required bool annotationRoom}) =>
    (verovioPageMarginTopDefault +
            (annotationRoom ? annotationPageMarginTopUnits : 0))
        .clamp(0, verovioPageMarginTopMax);

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
/// see [annotationRoomSpaces]. This shrink is the net underneath that: it catches
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
/// up at a 5px font. Against [annotationChannel] it only fires where the room
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
}) {
  final minScale = minStaffScaleFor(shortestSidePx);
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
/// Mirrors `measuresPerRowForWidth` in `models/piece_layout.dart` (which does the
/// same job for the jianpu/fingering views), with an extra step for iPad portrait.
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

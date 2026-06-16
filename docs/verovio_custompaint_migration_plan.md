# Migration Plan: Native Staff Rendering — Verovio engraving + Canvas drawing

Branch: `spike/verovio-rendering`. Companion: `docs/verovio_spike_notes.md`
(spike evidence) and the critique in `docs/replace_webview_plan_for_review.md`.

## Context

Today the staff view renders OSMD inside a `WebView`/iframe
(`assets/osmd/osmd_bridge.html`, driven by `lib/widgets/staff_view_io.dart` /
`staff_view_web.dart`). Two pains: (1) WKWebView is a Flutter platform view so
Marionette screenshots of notation are blank, and (2) selection is measure-only
and highlight color/animation is awkward (fixed-opacity SVG `<rect>`s inside the
bridge).

The spike proved the **Verovio engraving engine** is an excellent on-device
replacement (FFI, ~450ms, reflow, per-element bboxes, timemap, stable ids), and
that **Verovio was used correctly** — the only blocker was rendering its SVG
through `flutter_svg`, which lacks two things Verovio's (standard, browser-valid)
SVG relies on:

1. **Nested `<svg class="definition-scale" viewBox="0 0 18000 9280">`** — Verovio
   works in an 18000-unit space and scales via a nested-svg viewBox. flutter_svg
   ignores nested-svg viewBox → content drawn ~25× oversized, off-canvas.
2. **CSS `<style>` with `stroke:currentColor`** on all lines/stems/beams →
   flutter_svg drops `<style>` → strokes vanish.

A full browser renders this fine (why OSMD works). The fix is to **stop routing
Verovio's vectors through flutter_svg** and instead render them in Flutter's own
pipeline, where we also get native, fully-controllable selection/highlighting.

Key enabling fact from the spike: **Verovio's glyph ids are SMuFL codepoints**
(`<g id="E050">` = G-clef U+E050, `E0A4` = noteheadBlack, `E262` = sharp, …),
placed by `<use xlink:href="#E050" transform="translate(x,y) scale(s,s)">`. So
each glyph is "draw SMuFL `U+E050` at (x,y)·scale" — drawable either from the
**Bravura font** or from Verovio's **embedded glyph path** (`<g id="E050"><path
d="…"/>`). Non-glyph marks (staff lines, stems, beams, slurs, ties, barlines)
are `<path>`/`<rect>`/`<polygon>`; text (fingerings, tempo) is `<text>`.

## Goal

Replace the OSMD WebView staff with a native renderer: **Verovio for
layout/coordinates, Flutter Canvas for drawing**, with native overlays for
note-level selection, arbitrary-color highlighting, section tints, flagged
measures, and a native playback cursor. Keep the existing `StaffView` public API
so it's a drop-in behind a feature flag, with OSMD retained as fallback.

## Current state of the `spike/verovio-rendering` branch (READ FIRST)

This branch already carries working scaffolding from the evaluation spike — **do
not re-add these**:

- **Deps already in `pubspec.yaml`:** `verovio_flutter: ^0.3.1` and `flutter_svg`.
  CocoaPods install + iOS build are confirmed green (FFI plugin builds clean).
- **Working reference harness — `lib/spike/verovio_harness.dart`** (throwaway
  one-screen app). It already drives the whole Verovio pipeline end-to-end and is
  the canonical example to copy init/option/parse patterns from:
  `VerovioResourceManager.ensureVerovioAssetsReady()` →
  `VerovioAsyncService.spawn(resourcePath:)` → `setOptionsJson(jsonEncode(...))`
  → `loadData(xml)` → `renderPageWithHitMap(1)` (returns `(svg, PageHitMap)`) →
  `renderToTimemap()` / `getElementsAtTime()` / `getElementAttr()` /
  `getTimesForElement()`; plus the nested-svg-flatten + stroke-inline shim
  `_sanitizeForFlutterSvg`, reflow via width buckets, and `hitTestPointAll`.
- **Boot flag — `lib/main.dart`** has `const bool _kVerovioSpike` (currently
  `false` = real app). Flip to `true` to boot the harness for experiments.
- **Verovio API reference (full method table):**
  `~/.pub-cache/hosted/pub.dev/verovio_flutter-0.3.1/doc/api.md` and
  `options.md`; data classes `ElementHit` / `PageHitMap` / `hitTestPointAll` live
  in `.../verovio_flutter-0.3.1/lib/src/hit_map/`.

**Unknowns the spike could NOT confirm** (flutter_svg rendered the staff blank,
so nothing visual was ever tappable — these are not settled facts):
- Whether `ElementHit.bbox` and `PageHitMap.viewBox` are in the **outer page
  coordinate space** (e.g. `720×372`) that overlays/cursor will use, vs. Verovio's
  inner `18000`-unit space. The harness *assumes* outer (it maps taps via
  `screen / hitMap.viewBox.width`), but this was never visually validated.
- Whether `hitTestPointAll` / the bboxes actually align with the rendered glyphs.
  **Both must be verified in Phase 0** the moment something renders, before any
  overlay/cursor work is built on top.

## Phase 0 — De-risk the renderer choice (do FIRST, ~half day)

The biggest unknown is *how much renderer we must write*. Resolve it before
building anything large:

1. **Try `jovial_svg`** (a more SVG-compliant, CustomPaint-based Dart renderer —
   *not* a WebView; BSD-licensed; works on all platforms incl. web). Render
   Verovio's SVG (`svgViewBox:true`) with `ScalableImageWidget.fromSISource(
   ScalableImageSource.fromSvgString(...))`. Easiest harness: in
   `lib/spike/verovio_harness.dart`, swap the `SvgPicture.string(...)` for the
   jovial widget and screenshot via `xcrun simctl` (the staff WebView caveat does
   NOT apply — both flutter_svg and jovial_svg render in-pipeline, so Marionette/
   simctl capture them). If it renders faithfully (nested-svg viewBox + CSS
   `stroke:currentColor` + `<use>`/`<defs>`), the "renderer" is a dependency
   swap, not new code — overlays still drawn natively on top. Prove or kill first.
2. **Pin the id↔identity mapping AND verify bbox alignment** (load-bearing for
   selection + cursor):
   - **Mapping:** zip `renderToTimemap()` note-ons (sorted by `qstamp`) against
     our sounding notes from `ParsedPiece.performanceOrder()` (sorted by
     `beatPosition`, already computed in `HighlightEvent`,
     `lib/services/midi_generator.dart`). `qstamp == beatPosition` ⇒
     `noteId → (measureNumber, noteIndex)`. Disambiguate rare chords via
     `getElementAttr(id)` pitch. Measures: hitMap `type:'measure'` in document
     order ↔ our measure list. **Observed JSON shapes** (from the spike):
     - timemap entry: `{on:["df542eu"], off:[...], qstamp:0, tstamp:0, tempo:120}`
     - `getElementsAtTime(ms)` → `{measure:"sxyw96l", notes:["fqyy54d"], rests:[], chords:[], page:1}`
     - `getElementAttr(id)` → `{dur:"4", oct:"5", pname:"e", "stem.dir":"down"}`
   - **Alignment (the unverified bit):** once step 1 renders, draw a debug rect
     from `hitMap.byId[noteId].bbox` over a known note and confirm it lands on the
     glyph; tap it and confirm `hitTestPointAll` returns that id. This pins which
     coordinate space the bboxes are in. Everything downstream assumes overlays,
     glyphs, and bboxes share ONE space (the outer page viewBox, e.g. 720×372).

**Decision gate:** jovial_svg faithful + bboxes aligned → Renderer = jovial_svg
(skip Phase 2's painter). jovial_svg unfaithful → build the Canvas painter in
Phase 2. If bboxes are in the inner 18000 space, add a scale to the overlay layer.
Phases 1, 3, 4, 5 are identical either way.

## Phase 1 — Engraving service (`VerovioEngraver`)

New `lib/services/verovio_engraver.dart` (+ `_io`/`_web` conditional split;
`verovio_flutter` supports iOS/Android/Web). Wrap one long-lived
`VerovioAsyncService` (worker isolate) and expose:

```dart
Future<EngravedScore> engrave(String musicXml, {required double widthPx, double scale});
```

- Options: `svgViewBox:true, adjustPageHeight:true, breaks:'auto', footer:'none',
  header:'none', pageWidth: widthPx*100/scale, scale, mnumInterval`.
- Load `.xml` via `loadData`, `.mxl` via `loadZipDataBuffer`.
- Return `{svg, PageHitMap, timemapJson, viewBox}` and the id-correlation map.
- **Cache** by `(xmlHash, widthBucket, scale)` — reflow on rotation/resize and
  the live measure editor re-engrave (~450ms) hit the cache when unchanged.

`EngravedScore` / page model:
```dart
class EngravedScore {
  final Size viewBox;                         // post-scale page coords
  final String svg;                           // for jovial_svg path
  final Map<String, Rect> bboxById;           // hitMap, viewBox coords
  final List<NoteAnchor> notes;               // {measureNumber, noteIndex, qstamp(beat), Rect}
  final List<MeasureAnchor> measures;         // {measureNumber, Rect}
  final TimeMap timemap;                       // beat -> note ids on/off
  // Phase-2-only (custom painter): display list
  final List<GlyphOp>? glyphs;                // {codepoint, Offset, scale} or embedded Path
  final List<StrokeOp>? strokes;             // {Path, width, color}
  final List<TextOp>? texts;                 // {string, Offset, fontSize, italic/bold}
}
```

## Phase 2 — Canvas painter (only if Phase 0 gate fails)

Write a focused SVG→display-list walker for Verovio's small subset, then a
`CustomPainter`. Reuse what exists: `package:xml` is already a dependency; the
`verovio_flutter` package internally already walks the SVG and accumulates
transforms for its hit-map (`lib/src/hit_map/{walker,transform_parser,affine2d,
path_bbox}.dart`) — reference for the matrix math (do not import `src/`).

Walker: DFS the SVG, accumulate the CTM **including the nested-svg viewBox scale**
(the 18000→page mapping flutter_svg missed) and `<g transform>` chain. Emit in
final viewBox coords:
- `<use href="#Exxxx" transform>` → `GlyphOp(codepoint:0xExxxx, pos, scale)`.
- `<path d>` → parse `d` to `Path` (add `path_drawing` dep for `parseSvgPathData`,
  or vendor a small parser) → `StrokeOp`/fill.
- `<rect>`/`<polygon>`/`<polyline>` → `Path` → `StrokeOp`/fill.
- `<text>` → `TextOp`.

Drawing — **recommended v1: draw glyphs from Verovio's embedded `<defs>` paths**
(fill the def path under the `<use>` transform). This is pixel-identical to
Verovio and needs **no font-metric calibration**. *Optional later optimization:*
draw glyphs as Bravura font characters (`String.fromCharCode(codepoint)` via
`TextPainter`, Bravura bundled as a Flutter font) — lighter and crisper, but
requires calibrating em-scale against the glyph bbox. Either way it's
`CustomPaint`, fully native, Marionette-visible.

## Phase 3 — Interaction & native overlays (the actual feature win)

All native, identical for both renderer variants — drawn over the engraving via
a `Stack`/overlay painter, replacing the OSMD bridge's SVG overlays:

- **Selection:** hit-test taps against `notes`/`measures` bboxes → drive existing
  `MeasureSelection` (`lib/services/providers.dart`) and, newly, note-level
  selection. Replaces the `osmd_bridge.html` `measureTapped` round-trip.
- **Highlighting:** arbitrary-color/opacity/animated rects from bboxes — full
  control (the original ask). Reuse swatches from `lib/models/section_palette.dart`.
- **Section tints / flagged measures:** native rects/badges from measure bboxes
  (replaces `setSectionTints` / `setFlaggedMeasures` / flag dots in the bridge).
- **Fingering labels:** honor the `CLAUDE.md` rule — render
  `NoteEvent.fingerNumber` (e.g. `A2L`, `E2H`) **verbatim**. Prefer drawing them
  ourselves from our model at the note bbox rather than trusting Verovio text, so
  the L/H suffix is guaranteed intact (see `lib/widgets/fingering_view.dart` for
  the existing native label drawing).

## Phase 4 — Playback cursor (native)

Listen to `highlightNotifier` (`HighlightEvent.beatPosition`) → look up the note
via the timemap (`qstamp == beatPosition`) → its bbox → draw a native cursor
rect/line via the overlay painter. Reimplement page-turn autoscroll (the only
thing OSMD's cursor iterator gave for free): when the cursor enters the last
visible system, scroll so that system anchors near the top (mirror
`scrollWithPageTurn` logic from `osmd_bridge.html`). Backward seek (loop) just
re-looks-up the beat — no reset needed.

## Phase 5 — Integration behind a flag

- New widget `lib/widgets/staff_view_verovio.dart` exposing the **same public API
  as `StaffView`** — read `lib/widgets/staff_view_io.dart` for the authoritative
  constructor signature and the exact JS message contract (`positionCursor`,
  `setSelection`, `setSectionTints`, `setFlaggedMeasures`, `measureTapped`) this
  replaces. Params: `musicXml`, `highlightNotifier`, `selection`,
  `onMeasureTapped`, `flaggedMeasures`, `measureNumbers`, `sectionTints`,
  `scrollNav`, plus new note-level callbacks. Drop-in for the call sites:
  `lib/screens/piece_detail_screen.dart` (`_NotationView`) and the single-measure
  preview in `lib/screens/edit_measure_screen.dart` (which today uses
  `palette_bridge.html` — the engraver handles single-measure input too).
- Add a `staffRendererProvider` (enum: `osmd` | `verovio`) so we can switch at
  runtime and **keep OSMD as fallback**. Default stays `osmd` until parity.

## Phase 6 — Cross-platform, licensing, cleanup

- **Web:** verify `verovio_flutter` WASM path renders + overlays work.
- **macOS:** `verovio_flutter` has **no macOS support**, but `webview_flutter`
  *does* (10.15+ via `webview_flutter_wkwebview`). So set `staffRendererProvider`
  to `osmd` on macOS and `verovio` elsewhere — the renderer-by-platform split
  keeps macOS working. (macOS is a deferred target and is likely blocked anyway
  by other mobile-only plugins — `homr_omr`, `flutter_doc_scanner`,
  `image_cropper`.) Alternatively, fork `verovio_flutter` to add a `macos/` build
  target — Verovio's C++ compiles natively on macOS.
- **Licensing:** `verovio_flutter` is **LGPL-3.0**; note the static-FFI-link
  caveat before any App Store distribution. Bundle weight ~7 MB/ABI
  (`--split-per-abi` on Android).
- **Cleanup only after parity (flag default flipped to `verovio`):** remove
  `assets/osmd/*`, the `webview_flutter*` deps, the `staff_view_io/web.dart`
  bridge, **the spike artifacts (`lib/spike/`, the `_kVerovioSpike` flag in
  `lib/main.dart`)**, and `flutter_svg` if the jovial_svg/painter path didn't keep
  it. Keep the OSMD path only if macOS-via-OSMD is retained.

## Risks / open questions

- **Phase 0 is the pivot.** If jovial_svg works, this is a small project; if not,
  Phase 2's painter is the bulk of the effort. Don't build Phase 2 before the gate.
- SVG `d`→`Path` parsing (Phase 2) — use `path_drawing`; verify slurs/ties
  (filled beziers) and beams (`<polygon>`) render correctly.
- Glyph scaling if using Bravura-as-font (calibration) — avoided by the
  embedded-path default.
- id↔(measure,noteIndex) correlation under repeats/chords/grace notes — validate
  on `gossec_gavotte` and a sectioned (ABAA) piece; chords are rare for violin.
- Reflow latency on rotation (~450ms) — masked by cache + a brief layout hold.

## Implementation status (2026-06-16)

Implemented on `spike/verovio-rendering`:

- **Phase 0 — GATE PASSED.** Renderer = **`jovial_svg`** (added to `pubspec.yaml`).
  It parses `<style>`/`currentColor` (what flutter_svg dropped); the only shim is
  flattening Verovio's nested `<svg class="definition-scale">` → `<g scale>`
  (jovial throws on a 2nd `<svg>`). Verified faithful render + bbox alignment on
  iOS sim (`lightly_row`, `gossec_gavotte`). **Phase 2 (Canvas painter) skipped.**
  See `docs/verovio_spike_notes.md` addendum.
- **Phase 1 — `lib/services/verovio_engraver.dart`.** One long-lived
  `VerovioAsyncService`, serialized `engrave()`, `(xmlHash, widthBucket, scale)`
  cache, reflow. Returns `EngravedScore` (jovial-ready SVG + `viewBox` +
  index-based `MeasureAnchor`/`NoteAnchor`). Domain-free: measure document
  index ↔ model number is done by the widget via its `measureNumbers` list
  (the existing OSMD index↔number contract). Note→measure assignment is
  geometric (bbox containment + x-rank = positional `noteIndex`), which avoids
  fragile qstamp/tick alignment; qstamp is captured from the timemap as a
  fallback (`qstamp = beatPosition×4`).
- **Phases 3+4+5 — `lib/widgets/staff_view_verovio.dart`.** Drop-in with the
  same public API as `StaffView`. Native overlays: section tints (underlay),
  selection range, flagged-measure markers, current-note highlight + playback
  cursor (driven by `HighlightEvent`'s `(measureNumber, noteIndex)` directly —
  no qstamp needed). Page-turn autoscroll + `scrollNav`. Taps → `onMeasureTapped`.
  Wired behind `staffRendererProvider` (`providers.dart`) at both call sites:
  `piece_detail_screen.dart` (staff + staffFingering) and
  `edit_measure_screen.dart` (single-measure preview). Verified live on iOS sim:
  render, measure selection, cursor tracking, reflow, fingering labels (verbatim),
  ABAA section tints, and Marionette/`simctl` capture (no longer blank).

**Renderer policy (per user):** Verovio is the default and the only user-facing
renderer — there is **no UI toggle**. OSMD is retained as a code-only fallback
for environments where Verovio can't run (macOS). Maintaining/selecting that
fallback is deferred to a future task (see Phase 6).

**Phase 6 — DEFERRED (future task), no cleanup yet** (parity not fully proven):
per-platform `osmd` default on macOS; web WASM verification; LGPL-3.0 licensing
review; remove `assets/osmd/*` / `webview_flutter*` / `lib/spike/` / the bridge
only after cross-fixture parity. **Known limitation:** in unfolded/sectioned
(ABAA) mode the cursor maps a repeated measure number to its FIRST rendered copy
(`_anchorForEvent` uses `indexOf`); drive by performance-occurrence to fix.

## Verification

- **Side-by-side parity:** render every `assets/fixtures/*` under both renderers
  (flag toggle); compare engraving, selection, section tints, flagged measures,
  fingering labels (verbatim `A2L`/`E2H`), and cursor tracking through a full
  playback incl. repeats.
- **Marionette payoff:** confirm `take_screenshots()` now captures notation
  (no longer blank) — the debugging win.
- **Reflow:** rotate phone↔landscape and resize; systems re-break, overlays stay
  aligned.
- `flutter analyze` clean; existing tests pass; OSMD path still works when the
  flag is set to `osmd`.

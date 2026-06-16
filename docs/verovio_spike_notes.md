# Verovio Rendering Spike — Evidence & Decision Log

Throwaway branch `spike/verovio-rendering`. Nothing here ships. Plan:
`docs/replace_webview_plan_for_review.md` (critique) + approved spike plan.

## Step 1 — Dependency reality check  ✅ (positive)

Package: **`verovio_flutter` 0.3.1** (Verovio 6.2.1 native / 6.2.0 WASM). FFI on
native, WebAssembly on web — **no WebView, no JS bridge, no HTTP**, runs on a
worker isolate (`VerovioAsyncService`).

| Platform | Supported? |
|----------|-----------|
| iOS (≥13, arm64 device+sim) | ✅ |
| Android (≥API 21) | ✅ |
| Web (WASM) | ✅ |
| **macOS / Windows / Linux** | ❌ **not supported** |

Findings relevant to our requirements:
- **Reflow:** `setOptionsJson({pageWidth, pageHeight, scale})` → re-engrave per
  width. This is exactly what the rejected blueprint *couldn't* do. ✅
- **Per-element bboxes:** `renderPageWithHitMap(page)` → `{svg, hitMap}`;
  `hitTestPointAll(hitMap, offset)` → `List<ElementHit>` where `ElementHit` has
  `id`, `type`, `bbox: Rect`. First-class note-level hit zones + overlay anchors. ✅
- **Time-map:** listed among "all 38 Verovio API actions (render, MIDI,
  time-map, hit_map…)". Upstream `renderToTimemap` yields `{qstamp, on:[ids],
  off:[ids]}`; **`qstamp` (quarter-note position) maps directly to our
  `HighlightEvent.beatPosition`** → cursor path is plausible. ⚠️ confirm the
  binding surfaces it (build step).
- Input formats: MEI, **MusicXML**, MXL (`loadZipDataBuffer`), ABC, Humdrum.
  Our fixtures are MusicXML → `loadData(xmlString)`.
- Size: ~7 MB/ABI on Android with `--split-per-abi`.

### ⚠️ Cons surfaced at step 1 (carry into go/no-go)
1. **No macOS support.** `CLAUDE.md` lists macOS as a deferred-but-real target;
   Verovio's binding drops it. OSMD-in-WebView works on macOS today. Either keep
   OSMD as the macOS fallback (dual render path) or accept dropping macOS.
2. **LGPL-3.0.** Static FFI linking on iOS + LGPL relink obligations is a known
   App-Store gray area. Fine for a personal build; worth noting before any
   public iOS distribution.

Harness: `lib/spike/verovio_harness.dart`, booted as app home via a
`_kVerovioSpike` flag in `lib/main.dart` (flipped back to `false` after the run).
Build: `flutter pub add verovio_flutter flutter_svg` → pod install (2.4s) +
Xcode build (36.6s) **succeeded on iOS sim** with no native errors. The FFI
plugin builds clean. (Swift Package Manager not supported by the plugin — uses
CocoaPods; only a future-deprecation warning, same as our existing plugins.)

## Step 2 — Render fidelity harness  ❌ **BLOCKER**

Verovio renders fine (status line `OK · viewBox=720×372 · hits=73 · 438ms`) but
**flutter_svg draws the staff as blank.** Confirmed on both Marionette capture
*and* raw `xcrun simctl` framebuffer — not a screenshot artifact.

Root cause, from dumping the SVG (`[spike] SVG …` logs):
- The `<svg>` carries a single `<style>` block whose key rule is
  `… ellipse, path, polygon, polyline, rect { stroke: currentColor }`.
  Verovio draws **staff lines, stems, beams, barlines, slurs, ties** as stroked
  primitives whose stroke comes *only* from this CSS. flutter_svg logs
  `unhandled element <style/>` and drops it → all strokes vanish.
- Noteheads/clefs are `<use xlink:href="#E050-…" transform="translate(…) scale(0.72,0.72)">`
  referencing glyph `<g>` defs containing `<path transform="scale(1,-1)" d="M441 -245c…">`
  (font-design-unit coordinates).
- There is **no Verovio option to inline the CSS / disable the `<style>` block**
  (`options.md`: only `svgCss` to *add* CSS, `svgViewBox`, `svgHtml5`, …). The
  doc even states the intended highlight model is browser-DOM `getElementById` —
  i.e. it assumes a WebView, the very thing we're leaving.

Mitigations tried, still blank:
- `svgViewBox: true` → adds root `viewBox` (fixes scaling) — no content change.
- Shim: strip `<style>`, inline `stroke="#000000"` on every path/rect/polygon/
  polyline/ellipse → still blank.

Control test (proves the harness/render path is good): a hand-written
`_kProbeSvg` with a stroked `<line>`, a filled `<circle>`, and a `<use>` of a
`<defs><g><path>` **all render correctly** in the same `SvgPicture` widget.
So flutter_svg's `<use>/<defs>` works for simple cases; it's Verovio's
*specific* combination (CSS-only strokes + large-coordinate glyph paths placed
through nested `<use>`/`scale(1,-1)` transforms) that it cannot render.

→ Achieving fidelity would require a substantial, version-fragile SVG
normalizer (expand every `<use>`, inline the CSS as presentation attributes,
flatten transforms), with no guarantee flutter_svg's transform handling then
suffices. This is the "significant rework" `CLAUDE.md` anticipated.

## Step 3 — bbox + time-map + ID mapping  ✅ (all work)

Despite the render blocker, every data API we'd need works on-device:
- **Per-element bboxes:** `renderPageWithHitMap(1)` → `PageHitMap` with 73 hits;
  `ElementHit{id, type, bbox:Rect}` keyed by stable IDs. Note-level hit zones ✅.
- **Time-map:** `renderToTimemap()` → 58 entries, e.g.
  `{on:[df542eu], qstamp:0, tempo:120, tstamp:0}`. **`qstamp` = quarter-note
  position → maps directly to `HighlightEvent.beatPosition`.** ✅
- **time→element:** `getElementsAtTime(1000)` → `{measure:sxyw96l, notes:[fqyy54d,h2mabak]}`. ✅
- **ID→musical identity:** `getElementAttr('df542eu')` →
  `{dur:4, oct:5, pname:e, stem.dir:down}`; `getTimesForElement` returns qfrac
  on/off. So `(measureNumber, noteIndex)` is recoverable; `svgAdditionalAttribute`
  can even stamp `data-pname`/`data-oct` into the SVG. ✅

## Step 4 — Reflow probe  ✅ / cursor sketch ✅ (tractable)

- **Reflow works on-device:** phone bucket → `viewBox 720×372`; tablet bucket →
  `viewBox 1600×199`. Verovio genuinely re-broke systems for the wider width
  (not a stretch). Re-render ~380–500ms — fine for rotation; borderline for a
  per-keystroke live measure editor but acceptable.
- **Cursor path is tractable:** `beatPosition → qstamp` lookup in the timemap →
  element id → `hitMap.byId[id].bbox` → draw a native cursor rect. No OSMD
  cursor iterator needed. (Blocked only by the render fidelity issue above.)

## Step 5 — Marionette visibility  ✅ (the debugging payoff is real)

flutter_svg is **not** a platform view, so Marionette `take_screenshots()`
captures it (the probe shapes and all Flutter chrome show up). If rendering
worked, notation would be agent-visible — fixing the documented WebView
blank-rectangle limitation. (We already have the `xcrun simctl` workaround, so
this is a convenience, not a unique unlock.)

## DECISION — NO-GO on "Verovio + flutter_svg" as a drop-in render swap

**The Verovio *engine* is an excellent fit** (on-device FFI, reflow, per-element
bboxes, timemap, stable IDs, ~440ms, clean iOS build) and would unlock exactly
the note-level selection + colored-highlighting control the user wants.
**The renderer is the blocker:** flutter_svg cannot faithfully draw Verovio's
SVG, and the fix is a heavy/fragile SVG-normalization layer, not a small shim.

Per the approved plan's criteria → **fallback: incremental OSMD enhancement.**
Extend `assets/osmd/osmd_bridge.html` to emit per-*note* bounding boxes (it
already emits measure rects via `buildMeasureRects()`) and draw richer
overlays / note-level selection, keeping OSMD's proven rendering inside the
WebView. This gets the user's real goals (complex selection, full highlight
control) with far less risk. It does not fix Marionette screenshots, but the
`xcrun simctl` workaround already covers that.

**Kept on the shelf (larger project, only if off-WebView becomes a hard
requirement):** Verovio engine + a *capable* renderer — either a real SVG
normalizer, a different SVG engine, or `CustomPaint` driven by the package's
own parsed path geometry (its hit_map parser already converts paths to bboxes,
so the geometry is reachable). Bigger build; revisit if the incremental OSMD
path proves insufficient.

### Cons surfaced (for whenever Verovio is reconsidered)
- flutter_svg fidelity blocker (above) — the dominant one.
- **No macOS support** in `verovio_flutter` (CLAUDE.md lists macOS as deferred).
- **LGPL-3.0** static-FFI-link gray area for App Store distribution.
- ~7 MB/ABI asset weight.

## ADDENDUM 2026-06-16 — Phase 0 of the migration plan: GO (renderer = jovial_svg)

The NO-GO above was specific to **flutter_svg**. Phase 0 of
`docs/verovio_custompaint_migration_plan.md` re-tested with **`jovial_svg`**
(1.1.29; BSD; CustomPaint-based Dart renderer — *not* a WebView, so Marionette/
`simctl` capture it) and it **renders Verovio's SVG faithfully.** Decision gate
PASSED → use jovial_svg, **skip Phase 2's hand-written Canvas painter.**

Why jovial_svg works where flutter_svg failed:
- It **parses the `<style>` CSS block** into a stylesheet
  (`svg_parser.dart` ~L1066) and supports a **`currentColor`** parameter — the
  exact two things flutter_svg dropped (`stroke:currentColor` on all lines/
  stems/beams). No stroke-inlining shim needed.
- Only normalization required: jovial **throws "Second `<svg>` tag in file"**,
  so Verovio's nested `<svg class="definition-scale" viewBox="0 0 18000 …">`
  must be flattened to `<g transform="scale(ow/iw, oh/ih)">` (keep the `<style>`
  intact). Then `ScalableImage.fromSvgString(flat, currentColor: Colors.black)`
  → `ScalableImageWidget(si:…, fit: BoxFit.fitWidth)`.

Verified on iOS sim (harness `lib/spike/verovio_harness.dart`, renderer toggle +
all-note bbox debug overlay):
- **Fidelity:** `lightly_row` (clef, 2-sharp key sig, 4/4, filled+open
  noteheads, stems, beams, barlines) and `gossec_gavotte` (Allegretto, instrument
  labels, grace notes, dotted notes, rests, dynamics mf/p, Fine / D.C. al Fine,
  fingering digits) both engrave correctly.
- **bbox alignment (the previously-unverified bit):** the magenta debug rects
  hug every notehead, and a tap at vb `(190.4, 82.4)` returned
  `[note, measure]` matching the logged note bbox `LTRB(186.1,61.3,195.2,100.0)`.
  ⇒ `ElementHit.bbox` / `PageHitMap.viewBox` are in the **outer page viewBox
  space** (phone 720×885, tablet 1600×350), shared with the jovial render — so
  overlays/cursor map by a single `screen/viewBox` scale. No inner-18000 scale
  needed on the overlay layer.
- **Reflow:** phone bucket → viewBox 720×885; tablet bucket → 1600×350 (systems
  genuinely re-broke). ~460–795ms.
- **Marionette payoff:** the staff is now captured in screenshots (jovial is
  in-pipeline, not a platform view).

Cons still standing (carry forward): no macOS support → keep OSMD on macOS via
`staffRendererProvider`; LGPL-3.0 static-FFI caveat; ~7MB/ABI.

# Exploration Log — Pathways and Decisions

This document records the major paths explored during development, the
decisions made at each fork, and the reasoning behind them. It supersedes
`docs/PHASE1.md`–`PHASE4.md`, `docs/ux-improvements-plan.md`,
`docs/homr_flutter_integration.md`, `docs/flutter-best-practices-migration.md`,
`docs/omr_evaluation/{homr,oemer}/results.md`, and the Verovio-migration trio
(`docs/replace_webview_plan_for_review.md`, `docs/verovio_spike_notes.md`,
`docs/verovio_custompaint_migration_plan.md` — see §10) — those documents drove
the work described below and remain available in git history. Forward-looking
work lives in `docs/plan.md`.

---

## 1. Foundation (Phase 1 — MusicXML display)

**Stack chosen:** Flutter + Riverpod, Dart `xml` for MusicXML parsing, OSMD
(OpenSheetMusicDisplay) for staff notation rendered inside `webview_flutter`,
custom `CustomPainter`s for jianpu and fingering views.

**Why OSMD via WebView, not a native Dart renderer:** Music engraving is hard
to get right from scratch; OSMD is mature, MusicXML-native, and free. The
WebView cost (platform-view rendering quirks, asset bundling) was accepted
up front as the price of engraving quality. This is documented as a known
limitation in `CLAUDE.md` (Marionette screenshots are blank over the staff
WebView) — accepted rather than switching to `verovio_flutter`/SVG, which
would lose live cursor animation and require significant rework.

**Conditional-import pattern established from day one** (`*_io.dart` /
`*_web.dart`, e.g. `staff_view_io.dart` / `staff_view_web.dart`). This was a
deliberate early investment so that the "web-first while churning" posture
(see §8) wouldn't surface architecture-level surprises at the first mobile
build. It paid off directly: the OMR feature (§4) only needed a
`omr_service_io.dart` / `omr_service_web.dart` split, no retrofitting.

**Lookup tables in JSON, not Dart source** — `jianpu_key_map.json`,
`fingering_first_position.json`, `open_string_preferences.json`,
`midi_patch.json`. **Why:** a violin teacher should be able to correct a
fingering convention (e.g. "low 3" → "3") by editing one JSON file, not by
reading Dart code. This rule held throughout Phases 1–2 without exception.

**Fixture provenance — copyright-clean by construction.** All bundled
MusicXML fixtures are public-domain melodies (Lightly Row, Bach minuets,
Happy Farmer, Gossec Gavotte, etc.), with publisher-specific `<fingering>`,
`<technical>`, and editorial `<articulation>`/`<direction>` elements stripped
before commit. **Twinkle Twinkle was deliberately excluded** from the
hand-picked fixture set — reserved as the first real test case for the OMR
scanning pipeline (§4) rather than added as a clean fixture.

---

## 2. MIDI playback (Phase 2)

`flutter_midi_pro` + the GeneralUser GS soundfont (general-MIDI, free for
redistribution) was chosen over building a custom synth — no reason to
reinvent sample playback for a violin patch.

**Highlight architecture refactor** (commit `1b8020f`): playback highlighting
moved to a `ValueNotifier<int?>`-based model (`notifierForMeasure`,
`currentMeasureNotifier`) rather than rebuilding via Riverpod state on every
note. This was needed for per-note highlight granularity without excessive
widget rebuilds, and incidentally fixed a pickup-measure cursor bug (measure
0 / anacrusis handling) — see also §7 for how pickup measures are handled in
row layout.

All MIDI timing/patch constants live in `assets/lookup_tables/midi_patch.json`
per the same "no magic numbers in Dart" rule from Phase 1.

---

## 3. Section editor and the "bouncing ball" rejection (Phase 3)

**Bouncing ball playback indicator — considered and rejected.** A sub-beat
horizontal-position indicator (`AnimatedPositioned`, driven by
`measureOnsetSeconds`/`measureDurationSeconds`) was designed but not built.

**Why:** measure-level highlight already orients a non-music-reading parent
well enough. The bouncing ball would (a) expand `PlaybackService`'s API
surface for marginal benefit, and (b) **could not work in the OSMD WebView
staff view at all**, creating an inconsistent experience across the four
notation modes. Rejected in favor of consistency across modes.

**Teacher-video alignment (audio chroma + DTW) deferred to "Phase 5"** — never
started, not currently planned. If revisited, it remains a self-contained
addition (`AlignmentMap`, `chroma_params.json`/`dtw_params.json`) that doesn't
block anything else.

---

## 4. OMR engine selection (Phase 4) — the biggest fork in the project

The goal: on-device optical music recognition (photo → MusicXML), fully
offline, for Suzuki Book 1-level single-staff pieces.

### 4.1 Oemer — evaluated and rejected

[BreezeWhite/oemer](https://github.com/BreezeWhite/oemer) was benchmarked
against Lightly Row (57 notes) and Happy Farmer (112 notes), no-title crops,
positional accuracy (pitch + duration, no alignment tricks).

**Result: 30.4% (Lightly Row) and ~95% after removing one spurious note
(Happy Farmer) — both well below the 90% bar.**

**Root cause, and why it's fatal:** Oemer's segmentation model *detects* time
signature glyphs (Common 'C', Cut-common '₵') as a labeled class, but **no
code anywhere in the pipeline reads that label** to set beats-per-measure —
confirmed by grepping the entire `oemer` source tree. Beat structure is
inferred purely from barline spacing, which silently drops or misplaces half
notes. Since virtually all beginner violin repertoire is in Common or
Cut-common time, this is not a tunable parameter — it's an architectural gap.
Patching it would mean rewriting `build_system.py`'s beat-inference, which is
out of scope for a mobile embedding. **Oemer rejected.**

### 4.2 Audiveris and TensorFlow Moonlight — rejected without benchmarking

- **Audiveris**: mature, accurate, MusicXML output — but a Java/Swing desktop
  app. Embedding on iOS/Android would mean extracting the core pipeline and
  rewriting the native layer (months of work), and its **AGPL license may
  conflict with GPL + F-Droid distribution**. Not benchmarked; ruled out on
  embeddability + licensing alone.
- **TensorFlow Moonlight** (Google, Apache 2.0): explicitly marked
  "no official release; not ready for end users" as of 2025. Revisit only if
  it reaches production readiness.

### 4.3 Homr — evaluated and passed

[liebharc/homr](https://github.com/liebharc/homr), a transformer-based fork of
Oemer, was benchmarked the same way:

| Piece | Notes | Result |
|---|---|---|
| Lightly Row | 57 | **100%** |
| Happy Farmer | 112 | **96.4%** (4 minor rhythm/pitch errors, all in the final system) |
| Gossec Gavotte (full-page photo, 8 staves, repeats, D.C. al Fine) | 193 | **100%** |

Homr correctly parses Common/Cut-common time (Oemer's fatal flaw), outputs
standard MusicXML with no post-processing, and runs in ~3–4s/piece on Apple
Silicon. **It does not produce per-note confidence scores** — the original
"amber-flag uncertain notes" UX from the Phase 4 plan was dropped from scope
as a result (no good proxy was found that didn't amber-flag everything or
nothing).

**Preprocessing decision — 50% binarization is required, not optional.**
Photos taken from a physical book show bleed-through from the page behind.
Without binarization, Homr detected a **phantom 6th staff** in the
bleed-through region on Happy Farmer, inserting two spurious measures
(accuracy 24.1%). Five thresholds (40–80%) were tested; 40–60% are
equivalent (96.4%), 70%+ retains enough bleed-through to trigger the phantom
staff. 50% was picked as the canonical midpoint of the working range and is
baked into the `OmrService` preprocessing step.

### 4.4 From Python reference to on-device Flutter (Stage B, complete)

Homr's pipeline has two layers: ONNX models (segmentation + transformer
encoder/decoder, fully portable) and ~15 Python modules of orchestration
(OpenCV-based preprocessing, staff detection, symbol classification, MusicXML
assembly — none of it ONNX). The orchestration was ported to Dart (not a C++
wrapper) and packaged as a **self-contained Flutter package**,
`homr_flutter/packages/homr_omr/`, exposing a single
`OmrOrchestrator().recognise(png) → MusicXML` entry point plus a
`preprocessImage()` step for the binarization above.

VPC consumes it as a **sibling path dependency**
(`../homr_flutter/packages/homr_omr`) — both repos must be checked out
side-by-side. This was chosen over vendoring or a published package because
the OMR pipeline is still under active co-development with VPC and a path dep
keeps iteration fast; publishing can happen later if useful to others.

**Mobile build milestone reached 2026-06-01** (commit `1fc21d1`,
"First verified iOS device build"): `flutter build ios --no-codesign` and
`flutter build macos` both succeed bundling ~147MB of ONNX models. This
required bumping deployment targets to iOS 16.0 / macOS 14.0 (an
`flutter_onnxruntime` requirement) — the `ios/Podfile`, `macos/Podfile`, and
`Pods-Runner.*.xcconfig` includes were committed at this point per the
`CLAUDE.md` rule ("commit pod-install side effects only once a verified
mobile build has produced them"). `flutter build apk` remains unverified —
no Android SDK on the dev machine, an environment limitation rather than a
code issue.

**End-to-end accuracy on Suzuki Book 1: 17/18 perfect (SER=0%)**, documented
in `homr_flutter/docs/omr_evaluation/` (the canonical copy — the local
`docs/omr_evaluation/{homr,oemer}/` directory in this repo predates that and
holds only the original two-piece Stage A evaluation).

**Three upstream `abc-music` bugs** were found and patched while generating
ground-truth fixtures (`gitlab.com/chrisspen/abc-music`); patches are prepared
in `homr_flutter/docs/omr_evaluation/abc_bug_{10,14,15}*.patch` but not yet
filed — user-owned follow-up, not blocking.

---

## 5. UX iteration after first real-device testing

After testing on an iPhone SE 2022 (Dynamic Island, landscape), three tracks
were identified and prioritized by payoff/dependency:

- **Track A — auto-scroll to active measure** (jianpu/fingering views follow
  playback). **Done** (commit `00d0650`): calculated row-offset scroll via
  `ScrollController` + `currentMeasureNotifier`, no `GlobalKey`s needed.
- **Track B — compact layout for small phones**, in dependency order:
  - B1: 36pt AppBar (commit `0955be9`) — done.
  - B3 before B2 (sheet structure had to settle first): pill-only rest state
    for the bottom sheet, mini-bar peeks on playback start (commit
    `80c2f1c`) — done.
  - B2: mode switcher moved into the bottom sheet (same commit) — done.
  - Net effect: chrome reduced from ~90pt to a ~16pt pill at rest, leaving far
    more vertical space for the score on small phones.
- **Track C — measure selection UX** (tap affordance + range selection):
  **not done** — `_toggleMeasure` still only ever creates single-measure
  selections (`MeasureSelection(measure, measure)`), and no "tappable" visual
  affordance was added. Carried forward to `docs/plan.md`.

Subsequent layout work (staff-default view, always-visible play bar,
page-turn scroll, safe-area handling, build-hash display in debug AppBar —
commits `bee32d8` through `2b64baa`) extended this same compact-layout effort
but wasn't part of the original three-track plan; it responded to further
device testing.

---

## 6. Flutter best-practices migration

Produced by reviewing the codebase against the `flutter-all` plugin's
flutter-patterns skill. Status as of 2026-06-10:

- **Priority 1 (performance quick wins)** — done: `_NotationView` extraction,
  `_ActiveMeasureSelector` deduplication, const audit,
  `_CompactPieceLayoutState.initState` deferred via `addPostFrameCallback`
  (was crashing Happy Farmer).
- **Priority 2 (Material 3 widget upgrades)** — done: `_StringLabelPicker`
  now uses `SegmentedButton` (was `Radio` + `GestureDetector`, and `Radio` is
  deprecated since Flutter 3.32); `_CompactModeSwitcher` now uses `TabBar`
  (was hand-rolled `InkWell` + manual underline); Settings drawer title now
  uses `Theme.of(context).textTheme.titleLarge`.
- **Priority 3 (state management modernization)** — not done:
  `StringLabelStyleNotifier` still extends the deprecated `StateNotifier`;
  `MeasureSelection` still lives in `providers.dart` rather than its own
  model file. Carried forward.
- **Priority 4 (testing)** — partially done: unit tests exist for
  `MusicXmlParser`, `MidiGenerator`, and a regression test for the staff
  spacing slider (`staff_spacing_slider_test.dart`). `PieceLayout.compute` and
  provider-level/widget tests are still missing. Carried forward.
- **Priority 5 (multi-platform smell check)** — clean. `SchedulerBinding`
  usage in `piece_detail_screen.dart` confirmed to be the cross-platform
  `package:flutter/scheduler.dart` import.

---

## 7. Staff view layout: from injected breaks to OSMD auto-layout (2026-06-10)

**Original approach:** `PieceLayout.injectSystemBreaks()` injected
`<print new-system="yes"/>` at the start of every measure that begins a new
row in the jianpu/fingering layout (computed by `PieceLayout.compute`, N
measures per row + forced section breaks), so OSMD's staff view row breaks
matched the other two notation modes exactly.

**New approach (this commit):** the method (renamed
`PieceLayout.stripLayoutHints()`) now strips *all* print/page-layout elements
instead, and OSMD is configured with `pageFormat: 'Endless'` to compute its
own system breaks. A new **staff-spacing slider** (`staffSpacingProvider`,
exposed in the settings drawer) drives
`EngravingRules.MinSkyBottomDistBetweenSystems` /
`MinimumDistanceBetweenSystems` live.

**Why the change:** OSMD's own line-breaking, given a real viewport width, is
more legible than rows forced to match the jianpu/fingering grid (which uses
a fixed measures-per-row independent of actual note density). The trade-off
— **the staff view's row breaks now diverge from jianpu/fingering's** — was
accepted as worth it for staff-view readability. The spacing slider gives the
user control over the resulting vertical density.

`PieceLayout.compute`'s row-break formula was also adjusted (still used by
jianpu/fingering): pickup measures (measure 0) now share row 1 with the first
N real measures rather than counting against the row budget, so a piece with
an anacrusis gets 5 measures in row 1 instead of 4.

A regression test (`test/staff_spacing_slider_test.dart`) guards against
`staffSpacingMin == staffSpacingMax`, which was found to make the `Slider`
unable to claim drag gestures (drags leaked to the parent `Drawer`'s
swipe-to-close).

---

## 8. Multi-platform posture (ongoing discipline)

Stated explicitly in `CLAUDE.md`: web-first while features churn is fine, but
the conditional-import split (`*_io.dart`/`*_web.dart`) must stay clean so the
first mobile build doesn't surprise. This discipline was established in Phase
1 (§1) and held through the OMR integration (§4.4) and the iOS build
milestone — no retrofitting was needed for either. The "smell check after
every commit" checklist in `CLAUDE.md` is the enforcement mechanism going
forward.

---

## 9. Document scanner mode — keep VNDocumentCameraViewController (2026-06-11)

After getting the standard scan flow working end-to-end on a physical device
(§1.3 in `docs/plan.md`), the multi-page "ready for next scan"/save review
screen seemed like unnecessary friction for an app that only ever scans one
page. `flutter_doc_scanner` offers
`useAutomaticSinglePictureProcessing: true`, which swaps iOS's standard
`VNDocumentCameraViewController` for the plugin's own `AutoScanViewController`
(single capture button, Vision-based rectangle detection/perspective crop, no
review step).

**Tried and reverted.** On a real page of sheet music, `AutoScanViewController`'s
rectangle detection/crop was poor and its output had bad contrast — both of
which `VNDocumentCameraViewController`'s built-in document-scan mode handles
well (it does significant enhancement: edge detection, perspective correction,
and contrast/B&W cleanup tuned for documents). The standard scanner is "doing a
lot for us" that the auto-single-picture path doesn't replicate.

**Decision:** keep `getScannedDocumentAsImages(page: 1, imageFormat:
ImageFormat.jpeg)` without `useAutomaticSinglePictureProcessing`. The
multi-page review UI's "ready for next scan" framing is mildly confusing for
single-page use, but that's a copy/UX nit, not worth trading away VisionKit's
detection and contrast quality. If this is revisited, look for a way to
configure/relabel the existing `VNDocumentCameraViewController` review screen
rather than switching scanner implementations.

---

## 10. Off-WebView staff rendering: Verovio engine + jovial_svg (2026-06-16)

The OSMD-in-WebView staff (§1) carried two long-standing pains: (a) WKWebView
is a Flutter platform view, so Marionette screenshots over the staff are always
blank (documented in `CLAUDE.md`), and (b) selection was measure-only and
highlight color/animation was awkward (fixed-opacity SVG `<rect>`s injected into
`osmd_bridge.html`). A spike on throwaway branch `spike/verovio-rendering`
evaluated replacing it with a native render path, and the result shipped (merged
to `main`, commit `6dc720c`, behind a `staffRendererProvider` flag).

**Rejected first: the headless-OSMD + percentage-map blueprint.** An AI-generated
design (former `replace_webview_plan_for_review.md`) proposed running OSMD
headlessly in Node/`jsdom`, emitting flat SVG + a normalized 0–1 bounding-box
JSON map, and rendering it with `flutter_svg` + a `Stack` of `Positioned`
touch zones. Rejected because it (a) couldn't reflow (fixed engraving stretched
with `BoxFit.fill`, not re-broken per width) and (b) depended on `flutter_svg`,
which — as the spike then proved — cannot draw the SVG faithfully anyway.

**Engine verdict: Verovio is an excellent on-device fit.** `verovio_flutter`
0.3.1 (Verovio 6.2.x) runs as FFI on iOS/Android and WASM on web — no WebView,
no JS bridge, on a worker isolate. Everything we need works on-device: genuine
reflow (`setOptionsJson({pageWidth,...})` re-breaks systems, ~450ms), per-element
bboxes (`renderPageWithHitMap` → `ElementHit{id,type,bbox}`), a timemap
(`qstamp` = quarter-note position, maps to `HighlightEvent.beatPosition`), and
stable glyph IDs (SMuFL codepoints).

**Renderer was the whole fight.** The blocker was never Verovio — it was getting
its SVG into Flutter's pipeline:
- **`flutter_svg` → NO-GO.** It drops the `<style>` block (Verovio strokes all
  staff lines/stems/beams via `stroke:currentColor` CSS → they vanish) and
  ignores Verovio's nested `<svg class="definition-scale" viewBox="0 0 18000 …">`
  (content drawn ~25× oversized, off-canvas). A stroke-inlining shim still
  rendered blank. Fixing it would mean a heavy, version-fragile SVG normalizer.
- **`jovial_svg` → GO** (1.1.29, BSD, `CustomPaint`-based, all platforms incl.
  web — *not* a WebView, so Marionette/`simctl` capture it). It parses the
  `<style>` CSS and supports a `currentColor` parameter — exactly the two things
  flutter_svg dropped. **Only shim needed:** flatten Verovio's nested
  `<svg class="definition-scale">` to `<g transform="scale(…)">` (jovial throws
  "Second `<svg>` tag in file"), keeping the `<style>` intact. This made the
  renderer a dependency swap rather than new code → **the hand-written Canvas
  painter (the migration plan's Phase 2) was skipped entirely.**

**What shipped:**
- `lib/services/verovio_engraver.dart` — one long-lived `VerovioAsyncService`,
  serialized `engrave()`, cached by `(xmlHash, widthBucket, scale)`, reflow.
  Returns `EngravedScore` (jovial-ready flattened SVG + viewBox + index-based
  `MeasureAnchor`/`NoteAnchor`). **Note→measure assignment is geometric** (bbox
  containment + x-rank = positional `noteIndex`), deliberately chosen over
  fragile qstamp/tick alignment; qstamp is kept only as a fallback. Domain-free:
  the index↔model-number mapping stays in the widget via its `measureNumbers`
  list (the same contract OSMD used, see §4 / `plan.md` §2).
- `lib/widgets/staff_view_verovio.dart` — drop-in with `StaffView`'s public API.
  All the OSMD-bridge overlays are now **native** (drawn over the engraving in a
  `Stack`): section tints, selection range, flagged-measure markers, current-note
  highlight, and the playback cursor — driven directly by `HighlightEvent`'s
  `(measureNumber, noteIndex)`, no qstamp lookup. Page-turn autoscroll + scrollNav
  reimplemented natively. Wired at both call sites (`piece_detail_screen.dart`,
  `edit_measure_screen.dart`'s single-measure preview).

**Renderer policy (per user): Verovio is the default and the only user-facing
renderer — no UI toggle.** OSMD is retained as a *code-only* fallback for
environments where Verovio can't run. The big payoff: the staff is no longer
blank in Marionette/`simctl` screenshots (jovial is in-pipeline), so notation is
finally agent-visible.

**Cons accepted, carried forward as deferred work (see `plan.md`):**
`verovio_flutter` has **no macOS support** (so macOS must stay on OSMD via the
flag — but macOS is likely blocked by other mobile-only plugins anyway);
**LGPL-3.0** static-FFI-link is an App-Store gray area; ~7 MB/ABI weight. Phase 6
cleanup (removing `assets/osmd/*`, `webview_flutter*`, the bridge, `lib/spike/`)
is **not done** — held until cross-fixture parity is fully proven. **Known
limitation:** in unfolded/sectioned (ABAA) mode the cursor maps a repeated
measure number to its FIRST rendered copy (`_anchorForEvent` uses `indexOf`);
fixing it needs driving by performance-occurrence.

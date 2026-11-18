# Plan — Remaining Work

Open work only. Finished work has been pruned from this file. For how it was
built, see `docs/explore.md` and this file's git history. The 2026-10-08
cleanup removed the done scan flow (§1.1–1.3), measure selection (§2) and
note editor (§6) write-ups.

Items marked **(decision)** need a call from the project owner before anyone
builds anything.

---

## 1. Sections: detection with lead-ins, and note-level markers (next)

The staff can lay a piece out by section: each section starts its own line,
and a bar is split where a section starts on a lead-in (the Sections layout in
the app bar's size and layout menu). How good that
looks depends entirely on where the section markers sit.

### 1.1 Lead-ins as part of section detection

Landed: `SectionDetector.detect` finds strain boundaries from part labels,
repeats, the author's ABC lines (new), then 8/4-bar blocks. A boundary the
author put mid-bar is kept exactly. That covers a `[P:X]` before a lead-in,
and an ABC line that starts on one (Amazing Grace's `…| D4` / `D2 | G4…`).
The converter now writes both as positional `<direction>`s, which the parser
reads as `Measure.partLabelNote` / `lineStartNote`. Downbeat starts then move
back onto their lead-in: the first sounding note after the previous bar's
phrase end (a rest, a held-over note, a note of half a bar or more), falling
back to the opening pickup's length. A bar that ends on its phrase end has
none. The first section starts on the opening pickup itself, its lead-in; when
that pickup sits outside a `|:`, `sectionRuns` starts the replay on the `|:`
bar, so A still plays as A¹ and A². Existing pieces get this through "Re-detect sections" in the display
drawer. It re-converts the stored ABC source for the line hints, and asks
before it replaces anything.

Still open:

- **Lyrics.** Not used. The plan's "first syllable of a `w:` line marks
  the lead-in" is wrong for Gundagai, whose lead-in words ("Where the",
  "There's my") end the previous `w:` line while its lines open on the
  downbeat. A usable signal would be a sung word starting after a held note
  or extend.
- **Lines in a repeat tail.** A straight-through tail after the last `:|`
  is still tiled into 8/4-bar blocks; the author's lines could split it.
- **Marker drift.** The measure editor rebuilds a bar's notes in one run,
  so a mid-bar marker ends up after them. Detection ignores a marker past the
  bar's last note; re-detection takes fresh positions from the ABC source
  when the bars still line up.

### 1.2 Section markers on specific notes

`Section` already carries `startNote`, and everything downstream honours it:
tints, bar splits, the engraved measure map and `resolveSectionRanges`. The
measure editor can already put a marker on a note: select it, then use "Mark
section start" (`measure_edit_panel.dart` `_editSectionMarker`). But that is
buried. It means opening the editor bar by bar, and moving a marker onto a
lead-in means removing it in one bar and adding it in another.

Already note-level, ahead of this: a section run (`SectionRun.startNote` /
`endNote`) shares a split bar with its neighbour. Selecting it from the minimap
(`MeasureSelection.ofRun`) highlights exactly its tint on the Verovio staff,
and plays and loops from its lead-in to the next one, with the count-in
treating a mid-bar start as a pickup. Still whole-bar: the jianpu and
fingering views' selected cells.

Make marker placement at the note level a first-class part of working with
sections:

- From the score itself, tap a note to start a section there.
- Drag or nudge an existing marker onto a lead-in, or back to the downbeat,
  without deleting and recreating it.
- Show where a marker sits when it is mid-bar, so a lead-in start is visible
  as one.

Constraints already in the code: `startNote` counts visible, non-grace notes,
including rests and chord members. A marker always sits on a chord's primary
note (`ChordEditor.primaryIndexOf` in the editor, and `sectionBarSplits`), so
the UI should only offer primary notes.

### 1.3 Lead-ins across repeats

Landed for the plain case. Devil's Dream is written `e2 |: agae … A2 e2 :|
|: ceAe …`, and Galopede has the same shape (`d c |: … A4 A2 dc :| [P:B] …`).
The tail of the `:|` bar leads back into A and then on into B. When that tail
is the same music as the lead-in before the `|:`, detection starts B on it
(`B@9:5`). In "Layout by section", where that tail opens B's line, the staff
engraves the equivalent `|: e2 | … A2 :| e2 |: ceAe …` so each pass reads its
own lead-in (`movedRepeats`, `moveRepeatsOntoLeadIns`). The written score is
unchanged elsewhere. The tail belongs to the run it leads into: A² on the pass
that jumps back (and the cursor draws it on the pickup), B on the pass that
falls through. A run selection carries its pass (`MeasureSelection.startPerf`
/ `endPerf`), so playing B no longer starts on the first pass of bar 9.

Still open:

- **Endings.** A lead-in at the end of a first ending (Devil's Dream's
  `|1 … A2 e2 :|2`, leading back into B²) stays as written, before the `:|`.
  B² replays from its `|:`, and that `e2` stays with B¹. Moving it would mean
  dropping it from ending 1 and moving B's `|:` onto 9's tail, which is itself
  a split slice.
- **Voltas** are now honoured by `performanceOrder` (`Measure.endings`).

### 1.4 Offer to fold a written-out restatement into a repeat

Happy Farmer writes its A strain out twice (A A B C A) instead of `|: A :|`.
The bundled score stays as written, so the screen matches the printed sheet.
Since 2026-10-09 a thin white gap separates every pair of section washes
(`_UnderlayPainter.sectionGap`), so the seam between the two As shows.

For an imported or scanned tune there is no printed original to match. After
detection there (`PieceRepository.savePiece`), when two back-to-back sections
share a label, offer: *"A is played twice in a row. Write it as a repeat?"*
Detection already decides that the two are the same music; that is why both
are labelled A. Accepting rewrites the MusicXML with `|:`/`:|`, and
`performanceOrder` is unchanged. The same check could back a later action on
the minimap or the Re-detect button, but import is where it fits the workflow.

Two shapes:

- **Identical strains** (Happy Farmer's two As end alike) fold into a plain
  `|: A :|`.
- **Strains that differ only at the end** are a repeat with first and second
  endings, `|: A |1 … :|2 … |`. This needs detection to report "same up to
  the last bar or two" rather than only "same" (voltas are already in
  `performanceOrder`). Lead-ins at the end of ending 1 then
  carry the open problem in §1.3.

Never fold a bundled fixture. And keep the fold reversible (unfold back to
written-out) before offering it on existing pieces.

---

## 2. Note editor gaps

The measure editor (`measure_edit_panel.dart`) is built and in use. What it
still can't do:

- **Add a note to an empty measure.** homr sometimes emits an empty measure
  (e.g. `<measure number="9"/>` in `homr_minuet_b.xml`). It gets
  flagged, but insert works only after a selected note, so there is nothing
  to insert after.
- **Still out of scope:** cross-measure ties and multi-voice measures.
  (Edited bars are rebeamed: `MusicXmlBeamer` runs in
  `PieceRepository._repair`.)

---

## 3. Verovio renderer follow-ups

The native Verovio + jovial_svg renderer is the only renderer (see
`docs/explore.md` §10). Still open:

- **ABAA cursor bug.** In an unfolded performance order the cursor maps a
  repeated measure number to its first rendered copy.
  `EngravedMeasureMap.locate` and `firstIndexOf` resolve a number to its
  first copy. Fix by keying the lookup on the performance occurrence rather
  than the measure number.
- **Zoom is a menu now (2026-11-18), to verify on devices.** A magnifier in
  the piece screen's app bar opens a non-modal panel: Size (Fit whole piece,
  or Small / Medium / Large, fixed staff heights in mm) and Layout (Flowing /
  Sections / Page). Pinch, the measures-per-line slider and Lock exactly are
  gone; the size is per piece, no longer per orientation. Check the mm values
  by eye on the SE and an iPad (`staff_zoom.dart`, "The size control").
  Each size also sets Verovio's note spacing (`spacingLinear`: Small 0.15,
  Medium 0.2, Large 0.25; 0.2–0.25 in the annotated view), and Fit tightens
  or loosens it (0.15–0.3) to fill 90% of the screen. Still to watch: Fit's
  first open costs three or four extra engraves (disk-cached after), and
  the annotated view's width barely responds to spacing, so it squeezes less.
- **App bar overflow on small screens (decision).** Print moved into the
  gear drawer to make room for the view menu on a phone. The bar will keep
  gaining actions, so pick a folding rule rather than moving one at a time:
  e.g. a single overflow (⋮ or hamburger) holding the gear's drawer and Print
  on compact widths, with the tablet bar showing them inline. Research the
  platform patterns first (Material's top app bar overflow and adaptive
  actions, iOS toolbar/`UIMenu` overflow, how reading apps such as Books and
  forScore fold their bars) before choosing.
- **Abandon the `fit-to-screen` branch.** Its plain, scannable page for
  sharing a tune to another device has errors, and sharing a `.stringlings`
  file does the job better. Delete the branch once nothing on it is wanted.
- **Platforms: iOS and Android only** (decided 2026-11-17). Web was never
  finished (Verovio's WASM build drew no staff lines or stems), and macOS
  had no Verovio build (`verovio_flutter` has no macOS target) and is
  blocked by the mobile-only plugins (`homr_flutter`, `flutter_doc_scanner`,
  `image_cropper`). Both, with Linux and Windows and the OSMD WebView
  renderer that existed only for macOS, were removed. A port would be
  reimplemented from the Verovio path, adding siblings behind the existing
  `*_io.dart` façades.
- **Licensing review.** Reviewed 2026-11-17 (an agent's reading, not legal
  advice). Settled:
  - Verovio (LGPL-3.0) is linked *dynamically*: `VerovioFFI.framework` on
    iOS, a `.so` on Android. In a GPL-3.0 app whose whole source is public,
    it owes notices and source pointers, nothing more.
  - The homr models are AGPL, and none of their training data carries
    non-commercial terms.
  - Verovio's Liberation Serif 1.04 is "GPL v2 with font exception", not
    OFL. Reviewed and accepted as bundled font data.
  - Every component that the pub LICENSE files don't cover now has its
    notice on the licence page (`lib/services/bundled_licenses.dart`,
    `assets/engine/licenses/`): Verovio with its libraries and fonts,
    FluidSynth and the Android LGPL-2.1 synth libraries with source URLs,
    ONNX Runtime's third-party notices, the iOS pods, the Android Gradle
    libraries, and the GPL text itself.

  **Decided 2026-11-17: Android goes cleanly GPL.** The Android build
  currently puts AGPL homr in one APK with two proprietary Google
  components, and both have to go:
  - **Title recognition**, `com.google.mlkit:text-recognition`
    (`android/app/build.gradle.kts`, `TextRecognitionPlugin.kt`). This is
    the *bundled* variant: Google's closed library and the Latin model are
    compiled into our APK, and it runs without Play Services, so it is not
    a system service. The unbundled variant
    (`play-services-mlkit-text-recognition`) moves the model into Play
    Services but still links a closed client library. Neither is clean.
    Plan: build title recognition back into `homr_flutter` as open code
    with open models, on both platforms, and retire the ML Kit plugin.
    iOS Vision is a genuine OS framework, so it is a GPL-3 §1 System
    Library, but one engine on both platforms is simpler to keep
    consistent.
    **Done 2026-11-18:** homr_flutter 0.5.0's `TextReader` (PaddleOCR
    PP-OCRv5 mobile, Apache-2.0, on ONNX Runtime) reads titles on both
    platforms, and the ML Kit plugin and dependency are gone. It is more
    accurate than ML Kit and Vision on the corpus, but slower on a low-end
    Android phone (about 2 s; accepted for now). Results and the speed-up
    brief: `docs/title_ocr.md`, `docs/title_ocr_speed_brief.md`. The iOS
    Vision plugin went too, so there is one engine; both platform plugins
    are in git history at 8b18b5a.
  - **The document scanner**, `play-services-mlkit-document-scanner`
    (via `flutter_doc_scanner`). Its UI and processing run inside Google
    Play Services, but a closed client library is still in our APK, and
    Play Services is a Google app, not part of Android (AOSP). It is absent
    on de-Googled and Huawei phones. Calling it a System Library is
    arguable, not settled. Replace it on Android with the camera,
    photo-picker and cropper path that already exists.
  - Once both are gone, F-Droid's rules (which reject any proprietary
    dependency) are met too.
  - ML Kit also tries to send usage logs to Firebase. The document scanner
    still brings that in (`mlkit/common` and the Firebase transport are
    still in the APK after text recognition was removed); replacing the
    scanner ends it.
- **Cleanup:** `flutter_svg` is now used only by `verovio_engraver.dart`.
  (OSMD and `webview_flutter` went on 2026-11-17.)

---

## 4. Code hygiene

- **`StateNotifier` → `Notifier`** (Riverpod v2). These are on the
  deprecated base:
  - in `lib/services/providers.dart`: `MeasuresPerLineNotifier`,
    `StringLabelStyleNotifier`, `CountInNotifier`, `RecordingLeadInNotifier`,
    `TempoSettingsNotifier`, `PiecePerformanceOverrideNotifier`
  - `PieceActivityNotifier` (`piece_activity_store.dart`) and
    `MeasureEditController` (`measure_edit_session.dart`)
- **Move `MeasureSelection`** out of `providers.dart` into
  `lib/models/measure_selection.dart`. It's a plain value type.
- **Provider and widget test coverage.** Missing for:
  - `PieceLayout.compute` row grouping, including a pickup measure
  - the `parsedPieceProvider` chain against a mocked `PieceRepository`
  - `SectionMinimap` taps
  - `MediaControls` button state
- **`_hasPeeked`** on `_CompactPieceLayoutState` is a `static bool`, so it is
  shared across instances. Low priority; leave it unless it causes a bug.

---

## 5. Stale artifacts and housekeeping (decision)

- **`docs/omr_evaluation/`** (`homr/`, `oemer/`) is superseded by
  `homr_flutter/docs/omr_evaluation/`. It's a candidate for deletion.
- **Upstream `abc-music` patches**, prepared in
  `../homr_flutter_private_archived/docs/omr_evaluation/abc_bug_{10,14,15}*.patch`
  (they were not carried over to the public `homr_flutter`), are not yet
  filed. This is user-owned.

---

## 6. Device checks still owed

- **Scan flow:**
  - Cancel at the scan step and at the crop step returns cleanly, with no
    orphaned files.
  - A scanned page's note count matches the gold standard.
- **Section layout:**
  - portrait and `dev-ipad`
  - Lightly Row, Old Joe Clark and happy_farmer, for repeats and a section
    that starts on a pickup

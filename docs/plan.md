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
and a bar is split where a section starts on a lead-in ("Layout by section" in
the display drawer, with lines per section on the zoom slider). How good that
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
section start" (`edit_measure_screen.dart` `_editSectionMarker`). But that is
buried. It means opening the editor bar by bar, and moving a marker onto a
lead-in means removing it in one bar and adding it in another.

Already note-level, ahead of this: a section run (`SectionRun.startNote` /
`endNote`) shares a split bar with its neighbour. Selecting it from the minimap
(`MeasureSelection.ofRun`) highlights exactly its tint on the Verovio staff,
and plays and loops from its lead-in to the next one, with the count-in
treating a mid-bar start as a pickup. Still whole-bar: the jianpu and
fingering views' selected cells, and the OSMD overlay.

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
- **Voltas** are not in `performanceOrder` at all.

### 1.4 Offer to fold a written-out restatement into a repeat

Happy Farmer writes its A strain out twice (A A B C A) instead of `|: A :|`.
The bundled score stays as written, so the screen matches the printed sheet.
Since 2026-10-09 the second A's wash is a darker shade
(`SectionPalette.neighbour`), so the seam shows.

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
  the last bar or two" rather than only "same", and it is blocked on voltas
  entering `performanceOrder` (§1.3). Lead-ins at the end of ending 1 then
  carry the open problem in §1.3.

Never fold a bundled fixture. And keep the fold reversible (unfold back to
written-out) before offering it on existing pieces.

---

## 2. Note editor gaps

The measure editor (`edit_measure_screen.dart`) is built and in use. What it
still can't do:

- **Add a note to an empty measure.** homr sometimes emits an empty measure
  (e.g. `<measure number="9"/>` in `homr_15_minuet_no_3.xml`). It gets
  flagged, but insert works only after a selected note, so there is nothing
  to insert after.
- **Still out of scope:** cross-measure ties, multi-voice measures, and beam
  regeneration. Edited eighths render unbeamed.

---

## 3. Verovio renderer follow-ups

The native Verovio + jovial_svg renderer is the default (`staffRendererProvider`
→ `verovio`; see `docs/explore.md` §10). Still open:

- **ABAA cursor bug.** In an unfolded performance order the cursor maps a
  repeated measure number to its first rendered copy.
  `EngravedMeasureMap.locate` and `firstIndexOf` resolve a number to its
  first copy. Fix by keying the lookup on the performance occurrence rather
  than the measure number.
- **Parity sweep.** Render every `assets/fixtures/*` under both renderers and
  compare:
  - engraving, selection, section tints, flagged measures
  - fingering labels (verbatim `A2L`/`E2H`)
  - cursor tracking through a full playback including repeats
- **Per-platform default.** `osmd` on macOS (`verovio_flutter` has no macOS
  target), `verovio` elsewhere. macOS may be blocked anyway by the
  mobile-only plugins (`homr_omr`, `flutter_doc_scanner`, `image_cropper`).
- **Web.**
  - Confirm the `verovio_flutter` WASM path renders, and that the native
    overlays work in a browser.
  - The OSMD web iframe has no HTML→Dart channel, so tapping a measure on
    the staff does nothing on web (`staff_view_web.dart`).
- **Licensing review (decision).** `verovio_flutter` is LGPL-3.0, and the
  static FFI link needs a decision before any public App Store
  distribution. Bundle weight is about 7 MB per ABI.
- **Cleanup**, only once the default is firmly `verovio` everywhere it can
  be:
  - `assets/osmd/*`
  - the `webview_flutter*` deps
  - the `staff_view_io/web.dart` bridge
  - `lib/spike/` and `_kVerovioSpike` in `lib/main.dart`
  - `flutter_svg` (now used only by the spike and `verovio_engraver.dart`)

  Keep the OSMD path only if macOS-via-OSMD is retained.

---

## 4. Code hygiene

- **`StateNotifier` → `Notifier`** (Riverpod v2). Three notifiers in
  `lib/services/providers.dart` are on the deprecated base:
  - `MeasuresPerLineNotifier`
  - `StringLabelStyleNotifier`
  - `CountInNotifier`
- **Move `MeasureSelection`** out of `providers.dart` into
  `lib/models/measure_selection.dart`. It's a plain value type.
- **Provider and widget test coverage.** Missing for:
  - `PieceLayout.compute` row grouping, including a pickup measure
  - the `parsedPieceProvider` chain against a mocked `PieceRepository`
  - `SectionBar` taps
  - `PlaybackControls` button state
- **`_hasPeeked`** on `_CompactPieceLayoutState` is a `static bool`, so it is
  shared across instances. Low priority; leave it unless it causes a bug.

---

## 5. Stale artifacts and housekeeping (decision)

- **`docs/omr_evaluation/`** (`homr/`, `oemer/`, `scripts/`) is superseded by
  `homr_flutter/docs/omr_evaluation/`. It's a candidate for deletion.
- **`CLAUDE.md`** should say that OMR is mobile- and desktop-first, with web
  deferred to a possible server-side `homr` backend.
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

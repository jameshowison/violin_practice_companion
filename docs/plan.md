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
none. Existing pieces get this through "Re-detect sections" in the display
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

Devil's Dream is written `e2 |: agae … A2 e2 :| |: ceAe …`. The `e2` before
`:|` is a lead-in twice: back into A's second playing, then into B. It plays
exactly like `|: e2 agae … A2 :| e2 | ceAe …`, with the forward repeat before
the pickup and the backward repeat mid-bar. Each playing of A is then a
clean section that carries its lead-in, and B starts mid-bar on the `e2`.

Detection leaves a start at a repeat boundary on its downbeat, because the
model can't express this yet. Repeats are per bar (`Measure.repeatStart` /
`repeatEnd`), `ParsedPiece.performanceOrder` lists bars, and `sectionRuns`
labels whole bars, so a marker on that `e2` would tint it B on both passes.

- **Detection's part:** when the tail of a `:|` bar matches the strain's
  opening pickup (same durations and pitches), propose the moved repeats.
- **The model's part:** repeats at note positions. Probably done by splitting
  such a bar into two sub-measures in the model, as `splitBarsAtSections`
  already does for the staff, so playback and the cursor stay bar-granular.
- **Open:** whether the engraving shows the moved, mid-bar repeat or keeps
  the written one, and whether Verovio renders a `location="middle"` barline.

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

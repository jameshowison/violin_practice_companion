# Plan — Remaining Work

For the story of how we got here (engine selection, layout decisions, UX
iteration, etc.) see `docs/explore.md`.

## Next step

§1.1–1.3 are done (data model, repository persistence, scan UI), and the
scan-to-save round trip has been verified on a physical iPhone (profile mode,
USB-tethered — see §1.3's permissions note for the `Info.plist` fix that was
required). Playback of a scanned piece from the piece list has also been
confirmed working. What remains of **§1.4 Verification**: matches the
gold-standard note count, and survives an app restart (`index.json`
round-trip). Also confirm cancel-at-scan/cancel-at-crop return cleanly with no
orphaned files.

The "ready for next scan" review-screen UX (single-page-only scans) was
investigated and the standard `VNDocumentCameraViewController` flow was kept
as-is — see `docs/explore.md` §9.

---

## 1. Scan-to-practice flow (active)

The OMR seam is solid and verified end-to-end at the package level
(`OmrService().scan()` → MusicXML string, see `docs/explore.md` §4). What's
missing is the UI to trigger a scan and the persistence to turn the result
into a `Piece` the rest of the app can use:

```
OmrService().scan(onProgress: ..., title: 'My Piece')
  → (capture, preprocess, crop — VPC-side)
  → OmrOrchestrator().recognise(croppedPng, title: 'My Piece', onProgress: ...)
  → MusicXML 4.0 string
  → MusicXmlParser.parse(musicXml) → ParsedPiece (existing VPC code)
  → PieceRepository.savePiece(title, musicXml) → Piece
```

Everything downstream of `MusicXmlParser.parse` already works for bundled
fixtures — this work is entirely about getting a scanned MusicXML string into
a `Piece` the existing playback/notation UI can consume.

### 1.1 Data model changes — done

`lib/models/piece.dart`: `musicXmlAssetPath` and `sectionsAssetPath` are now
nullable; added `musicXmlFilePath` (nullable). A constructor assert enforces
exactly one of `musicXmlAssetPath`/`musicXmlFilePath` is set. `copyWith`
passes the new field through unchanged.

### 1.2 PieceRepository changes — done

Added a `piece_storage` module following the existing
`omr_service_io.dart`/`omr_service_web.dart` conditional-import pattern
(`dart:io` isn't available on web):
- `lib/services/piece_storage_io.dart`: `loadScannedPieces()`,
  `saveScannedPiece(title, musicXml)`, `readScannedMusicXml(path)`. Writes
  `<docs>/scanned_pieces/<slug>_<timestamp>.musicxml` +
  `<docs>/scanned_pieces/index.json` (`{id, title, musicXmlFilePath}` list).
  ID = slugified title + `DateTime.now().millisecondsSinceEpoch` (no new
  `uuid` dependency needed).
- `lib/services/piece_storage_web.dart`: stub — `loadScannedPieces()` returns
  `[]`, `saveScannedPiece`/`readScannedMusicXml` throw `UnsupportedError`
  (matches `omr_service_web.dart`'s stance that scanning is unavailable on
  web).
- `lib/services/piece_storage.dart`: conditional export.

`PieceRepository.loadAll()` appends `loadScannedPieces()` to the fixture
list; `loadMusicXml()` branches on which path field is set;
`savePiece(title, musicXml)` delegates to `saveScannedPiece`. Section
persistence skipped for v1 (scanned pieces have `sections: const []`), as
planned.

### 1.3 Scan UI flow — done

`lib/screens/scan_screen.dart`: title field (defaults to
`Untitled <ISO timestamp>` if empty) → "Scan" button →
`OmrService().scan(onProgress: ..., title: ...)`, with a progress label
driven by `OmrScanStage`. `null` result (user cancel) pops back with no
error. On success, `PieceRepository.savePiece()` + `ref.invalidate(piecesProvider)`,
then navigates to `PieceDetailScreen`. Errors are caught generically (covers
`OmrException` plus other pipeline failures) and shown in an AlertDialog with
Cancel/Retry.

Entry point: `FloatingActionButton.extended` ("Scan a page") on
`PieceListScreen`.

**iOS permissions (required for physical-device builds):** `ios/Runner/Info.plist`
needed `NSCameraUsageDescription` (for `flutter_doc_scanner`'s
`VNDocumentCameraViewController`) and `NSPhotoLibraryUsageDescription` (for
`image_cropper`). Without these, iOS hard-aborts the process the instant the
camera is requested — the UI appears to "hang" on the scanner's placeholder
screen with no camera feed, then the whole app dies (`abort with payload`).
Both keys are now in `Info.plist`. This doesn't affect the simulator (which
fails earlier, before touching the camera permission system).

### 1.4 Verification

- ✅ Scan-to-save round trip verified end-to-end on a physical device
  (iPhone, profile mode, tethered via USB): scan completed without errors,
  `PieceRepository.savePiece()` succeeded.
- Remaining: confirm the imported piece plays back correctly from the piece
  list (staff view + jianpu/fingering + MIDI playback) and matches the
  gold-standard note count for the scanned page.
- Confirm cancel-at-scan and cancel-at-crop both return cleanly with no
  orphaned files.
- Confirm a second app launch still shows the scanned piece (`index.json`
  round-trip).

---

## 2. UX follow-ups (deferred from `docs/explore.md` §5)

**Track C — measure selection UX.** `_toggleMeasure` in
`piece_detail_screen.dart` only ever creates single-measure selections
(`MeasureSelection(measure, measure)`). Two pieces remain:
- **C1 — discoverability**: give each measure container a subtle permanent
  background (`Colors.grey.shade100`) so it reads as tappable; flash
  `primaryContainer` on tap before settling into the selected highlight.
- **C2 — range selection**: `{S..S}` selected + tap `M != S` →
  `{min(S,M)..max(S,M)}`; tap inside an existing range → clear; tap outside →
  start a new single-measure selection. Add a small "drag to extend" hint
  (`→`) when exactly one measure is selected.

Files: `piece_detail_screen.dart` (`_toggleMeasure`), `jianpu_view.dart`,
`fingering_view.dart`. Do C1 before C2 — the visual feedback should be in
place before range selection lands.

---

## 3. Code cleanup / hygiene follow-ups

- **`StateNotifier` → `Notifier`** (Riverpod v2):
  `StringLabelStyleNotifier extends StateNotifier<StringLabelStyle>` in
  `lib/services/providers.dart` is on a deprecated base class.
- **Move `MeasureSelection`** out of `providers.dart` into its own
  `lib/models/measure_selection.dart` (it's a plain value type, not a
  provider concern). Update imports in `providers.dart`,
  `piece_detail_screen.dart`, `measure_selector.dart`.
- **Provider/widget test coverage**: `PieceLayout.compute` (row grouping for
  given measures-per-row, including the pickup-measure case from
  `docs/explore.md` §7), `parsedPieceProvider` chain with a mocked
  `PieceRepository`, `MeasureSelector` tap/drag, `SectionBar` tap,
  `PlaybackControls` button state.
- **`_hasPeeked` static bool** on `_CompactPieceLayoutState` — shared across
  instances via `static`. Works but is surprising. Low priority; leave unless
  it causes a bug.

---

## 4. Stale-artifact decisions (not yet made)

- **`piece_repository.dart`'s `abc_*`/`homr_*` OMR-comparison fixtures**
  (songs 05/10/14/15/17, 10 pieces): decide keep-as-demo (shows OMR quality
  side-by-side) vs. remove now that the real scan flow (§1) exists.
- **`docs/omr_evaluation/`** (`homr/`, `oemer/`, `scripts/compare_omr.py` +
  `__pycache__`): predates the current pipeline, which now lives in
  `homr_flutter/docs/omr_evaluation/` with a fuller (17/18) evaluation. The
  two-piece results here are superseded — candidate for deletion, but
  re-check whether anything in §1 above ends up referencing these images
  before removing.
- **`CLAUDE.md`**: should eventually note that OMR is mobile/desktop-first
  with web deferred to a possible future server-side `homr` backend.

---

## 5. Repo housekeeping

- **Push commits**: 5 unpushed commits in `homr_flutter`
  (`de872d3`, `afd8373`, `2771025`, `53b98af`, `e906c03`) and 5 in this repo
  (`413eaa4`, `63f5732`, `6f39721`, `9b43fa0`, `53bd8f1`). Push when ready.
- **Upstream `abc-music` patches**: prepared in `homr_flutter`
  (`docs/omr_evaluation/abc_bug_{10,14,15}*.patch`,
  `abc_music_upstream_issue.md`), not yet filed at
  `gitlab.com/chrisspen/abc-music`. User-owned, not blocking.

# OMR Integration Plan — Scan-to-Practice

Date: 2026-06-10
Status: **active — driven from this repo (violin_practice_companion)**

This supersedes `homr_flutter/docs/vpc_integration_and_review_plan.md` (now
removed). That document covered extracting `homr_flutter`'s OMR pipeline into
a consumable package and wiring it into this app's build; that work is done.
This plan picks up from there: the remaining work is entirely in this repo
(VPC) — the scan → recognise → import → practice user flow and its
persistence.

## 1. Done (for reference)

All of this was completed 2026-06-10 and is committed (not pushed):

- **Package extraction** (`homr_flutter` commit `de872d3`): OMR runtime moved
  to `homr_flutter/packages/homr_omr/`, a self-contained Flutter package with
  barrel export `package:homr_omr/homr_omr.dart` exposing:
  - `OmrOrchestrator().recognise(Uint8List png, {onProgress, title, artifactDir, pencilGateThreshold}) → Future<String>` (MusicXML 4.0 string)
  - `OmrStage` enum: `{segmenting, detecting, recognising, assembling}`
  - `OmrException`
  - `preprocessImage(Uint8List jpeg) → Future<PreprocessResult>` (binarization)
- **VPC dependency + conditional-import scaffold** (VPC commit `63f5732`):
  - `pubspec.yaml`: `homr_omr` as sibling path dep (`../homr_flutter/packages/homr_omr`), plus `flutter_doc_scanner` and `image_cropper`.
  - `lib/services/omr_service_base.dart`: `OmrScanStage` enum `{capturing, preprocessing, cropping, segmenting, detecting, recognising, assembling}` and abstract `OmrServiceBase.scan({onProgress, title}) → Future<String?>`.
  - `lib/services/omr_service_io.dart`: real implementation — doc scanner → `preprocessImage` → `image_cropper` → `OmrOrchestrator().recognise(...)`.
  - `lib/services/omr_service_web.dart`: stub throwing `UnsupportedError` (web has no ONNX runtime / doc scanner).
  - `lib/services/omr_service.dart`: conditional-export barrel (`if (dart.library.html)` pattern, matching `playback_service.dart`).
- **Mobile build milestone** (plan §3.5): `flutter build ios --no-codesign` and
  `flutter build macos` both succeed and bundle the ~147MB of ONNX models
  under `flutter_assets/packages/homr_omr/assets/models/`. Required bumping
  deployment targets to iOS 16.0 / macOS 14.0 (`flutter_onnxruntime`
  requirement) — done in `ios/Podfile`, `macos/Podfile`, and both
  `project.pbxproj` files. `flutter build apk` not verified (no Android SDK on
  this machine — environment limitation, not a code issue).
- **README** (VPC commit `6f39721`): documents the OMR pipeline, the sibling
  repo requirement, mobile/desktop-only + web stub, deployment targets, AGPL
  model licensing, and corrected the accuracy figure to **17/18 perfect
  (SER=0%)**.
- **Code review items** from the original plan's §4: R1 (no `dart:io` outside
  `*_io.dart`, verified by web build), R3 (no `path_provider` leakage at
  package boundary), R6 (sweep test stays the regression gate, 17/18) are
  done. R2 (static `OrtSession` caching/disposal), R4 (title handling), R5
  (repertoire-tuned post-processing — documented in homr_flutter README), and
  R7 (AGPL — noted in VPC README) are reviewed but not actioned further; see
  §5 below if they need follow-up.
- **Upstream `abc-music` bug reports** (homr_flutter commit `afd8373`): three
  patches prepared (`docs/omr_evaluation/abc_bug_{10,14,15}*.patch`,
  `abc_music_upstream_issue.md`) for `gitlab.com/chrisspen/abc-music`. Not yet
  filed — that's on the user, not blocking app work.

## 2. Remaining work: scan → import → practice flow

This is the actual feature. The seam is solid (`OmrService.scan()` returns a
MusicXML string or `null`); what's missing is the UI to trigger a scan and the
persistence to turn the result into a `Piece` the rest of the app can use.

### 2.1 Data model changes

`lib/models/piece.dart` currently:
```dart
class Piece {
  final String id;
  final String title;
  final String musicXmlAssetPath;
  final String sectionsAssetPath;
  final List<Section> sections;
}
```

Both path fields assume `rootBundle` assets. Scanned pieces are written to the
app's documents directory at runtime, so they need a non-asset path. Proposed:

- Add `final bool isUserScanned` (or equivalently, make the existing fields
  nullable and add `musicXmlFilePath`/`sectionsFilePath` alternatives — pick
  whichever keeps `loadMusicXml()` simplest). Recommendation: add
  `musicXmlFilePath` (nullable) alongside the existing
  `musicXmlAssetPath` (also made nullable); exactly one is set per piece.
  Same pattern for sections, but sections are optional anyway (user-scanned
  pieces start with no section annotations — `sections: const []`).
- `copyWith` already exists for `sections`; no change needed there beyond
  whatever new fields are added.

### 2.2 PieceRepository changes

`lib/services/piece_repository.dart` (112 lines) currently has:
- `_fixtures`: static list of bundled demo pieces (3 core + 9 `abc_*`/`homr_*`
  OMR-comparison pairs for songs 05/10/14/15/17).
- `loadAll()` and `loadMusicXml()`: both `rootBundle.loadString` only.

Needed additions:
- A `savePiece(String title, String musicXml) → Future<Piece>` method:
  - Get app documents dir (`path_provider`'s `getApplicationDocumentsDirectory()`).
  - Write `<docs>/scanned_pieces/<id>.musicxml` (id = slug of title + timestamp
    or uuid to avoid collisions).
  - Construct and return a `Piece` with `musicXmlFilePath` set,
    `musicXmlAssetPath: null`, `sections: const []`.
  - Persist a small index (e.g. `<docs>/scanned_pieces/index.json`, a list of
    `{id, title, musicXmlFilePath}`) so `loadAll()` can pick these up on next
    launch — this is the only new "database" needed; no need for sqlite/hive
    for this scale.
- `loadAll()`: after building the fixture list, read `index.json` (if it
  exists) and append the user-scanned pieces.
- `loadMusicXml(Piece piece)`: branch on which path field is set —
  `rootBundle.loadString(musicXmlAssetPath)` vs. `File(musicXmlFilePath).readAsString()`.
- Section persistence for scanned pieces: skip for v1 (empty `sections`); the
  existing section-editing UI (if any) should work against an in-memory
  `Section` list and a `saveSections()` that writes
  `<docs>/scanned_pieces/<id>_sections.json` — only build this if the app
  already has a section-editing UI to hook into. Check
  `lib/screens/piece_detail_screen.dart` (currently has uncommitted unrelated
  changes) before adding new UI here.

### 2.3 Scan UI flow

New screen, e.g. `lib/screens/scan_screen.dart`:

1. Title entry (text field, optional — defaults to "Untitled" or a timestamp).
2. "Scan" button → `OmrService().scan(onProgress: ..., title: ...)`.
3. Progress UI driven by `OmrScanStage` — a simple stepper or progress label
   is enough (`capturing` → `preprocessing` → `cropping` → `segmenting` →
   `detecting` → `recognising` → `assembling`). The on-device pipeline takes
   up to ~15s per the homr_flutter performance budget, so a progress
   indicator matters for UX.
4. On `null` result (user cancelled scan or crop): pop back, no error.
5. On success: `PieceRepository.savePiece(title, musicXml)`, then navigate to
   the piece detail/practice screen for the new piece (reuse whatever
   navigation the existing fixture pieces use).
6. On `OmrException`: show an error dialog with a retry option — don't crash;
   the on-device pipeline can fail on poor scans (see homr_flutter's
   `docs/omr_evaluation/remaining_issues.md` for known failure modes like
   spine-fold clef clipping).

Entry point: add a "Scan a page" action to wherever the piece list /
home screen is (likely a FAB or app-bar action).

### 2.4 Verification

- Manual end-to-end test on a physical device: scan a known Suzuki Book 1 page
  (e.g. Lightly Row, which is the cleanest 0%-SER case), confirm the imported
  piece plays back correctly (staff view + jianpu/fingering rendering + MIDI
  playback) and matches the gold-standard note count.
- Confirm cancel-at-scan and cancel-at-crop both return cleanly to the
  originating screen with no orphaned files.
- Confirm a second app launch still shows the scanned piece (index.json
  round-trip).

## 3. Open items (lower priority / deferred)

- **VPC `CLAUDE.md`**: should eventually note that OMR is mobile/desktop-first
  with web deferred to a future server-side `homr` backend. Not yet done —
  needs explicit go-ahead to edit this repo's instruction file.
- **Stale docs in this repo** (from the old plan's §5 "VPC-side stale
  duplicates"):
  - `docs/homr_flutter_integration.md` (295 lines) — a stale Phase-0 copy of
    homr_flutter's integration doc. Now fully superseded by §1 above and by
    homr_flutter's own docs. Candidate for deletion.
  - `docs/omr_evaluation/` — contains `homr/`, `oemer/`, `scripts/` subdirs
    (OMR engine comparison artifacts: musicxml + teaser PNGs + a
    `compare_omr.py` script + `.DS_Store`). This predates the current
    homr_flutter pipeline (which now lives in
    `homr_flutter/docs/omr_evaluation/`). Candidate for deletion, but check
    whether `piece_repository.dart`'s `abc_*`/`homr_*` fixtures or any
    comparison screen reference these files first.
  - `piece_repository.dart`'s `abc_*`/`homr_*` OMR-comparison fixtures (songs
    05/10/14/15/17) — decide keep-as-demo (useful for showing OMR quality) vs.
    remove now that the real scan flow exists.
- **Code review follow-ups** (from old plan §4, not actioned):
  - R2: confirm `OrtSession`s in `homr_omr` are cached statically and not
    re-created per scan (perf — relevant once real scans are frequent).
  - R4: title handling — confirm `OmrService.scan(title: ...)` round-trips
    into the MusicXML work-title and that `savePiece` uses it consistently.
- **Upstream `abc-music` patches**: prepared in homr_flutter
  (`docs/omr_evaluation/abc_bug_{10,14,15}*.patch`,
  `abc_music_upstream_issue.md`), not yet filed at
  `gitlab.com/chrisspen/abc-music`. User-owned, not blocking.
- **Pushing commits**: 4 commits in homr_flutter (`de872d3`, `afd8373`,
  `2771025`, `53b98af`) and 2 in VPC (`63f5732`, `6f39721`) are made locally,
  not pushed. Push when ready.

## 4. Reference: the integration seam

```
OmrService().scan(onProgress: ..., title: 'My Piece')
  → (capture, preprocess, crop — VPC-side)
  → OmrOrchestrator().recognise(croppedPng, title: 'My Piece', onProgress: ...)
  → MusicXML 4.0 string
  → MusicXmlParser.parse(musicXml) → ParsedPiece (existing VPC code)
  → PieceRepository.savePiece(title, musicXml) → Piece
```

Everything downstream of `MusicXmlParser.parse` already exists and works for
the bundled fixture pieces — the new work in §2 is entirely about getting a
scanned MusicXML string into a `Piece` that the existing playback/notation UI
can consume.

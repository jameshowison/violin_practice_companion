# Plan — Remaining Work

For the story of how we got here (engine selection, layout decisions, UX
iteration, etc.) see `docs/explore.md`.

## Next step

Start **§1.1 Data model changes** below — `Piece` needs file-path fields
before `PieceRepository.savePiece()` (§1.2) or the scan UI (§1.3) can be
built. This is the active feature; everything else in this file is
lower-priority and can wait.

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

### 1.1 Data model changes

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
app's documents directory at runtime, so they need a non-asset path.

**Recommendation:** add `musicXmlFilePath` (nullable) alongside the existing
`musicXmlAssetPath` (also made nullable); exactly one is set per piece. Same
pattern for sections, but sections are optional anyway (user-scanned pieces
start with `sections: const []`). The existing `copyWith` for `sections`
needs no change beyond whatever new fields are added.

### 1.2 PieceRepository changes

`lib/services/piece_repository.dart` currently has:
- `_fixtures`: static list of bundled demo pieces (3 core + 10 `abc_*`/`homr_*`
  OMR-comparison pairs, songs 05/10/14/15/17 — see §3 for their fate).
- `loadAll()` and `loadMusicXml()`: both `rootBundle.loadString` only.

Needed additions:
- `savePiece(String title, String musicXml) → Future<Piece>`:
  - Get app documents dir (`path_provider`'s `getApplicationDocumentsDirectory()`).
  - Write `<docs>/scanned_pieces/<id>.musicxml` (id = slug of title + uuid/timestamp
    to avoid collisions).
  - Construct and return a `Piece` with `musicXmlFilePath` set,
    `musicXmlAssetPath: null`, `sections: const []`.
  - Persist `<docs>/scanned_pieces/index.json` (list of
    `{id, title, musicXmlFilePath}`) — the only new "database" needed; no
    sqlite/hive at this scale.
- `loadAll()`: after building the fixture list, read `index.json` (if present)
  and append user-scanned pieces.
- `loadMusicXml(Piece piece)`: branch on which path field is set —
  `rootBundle.loadString(musicXmlAssetPath)` vs.
  `File(musicXmlFilePath).readAsString()`.
- Section persistence for scanned pieces: skip for v1 (empty `sections`). If
  the app already has section-editing UI, hook a `saveSections()` writing
  `<docs>/scanned_pieces/<id>_sections.json` against an in-memory `Section`
  list — only build this if that UI already exists.

### 1.3 Scan UI flow

New screen, e.g. `lib/screens/scan_screen.dart`:

1. Title entry (text field, optional — defaults to "Untitled" or a timestamp).
2. "Scan" button → `OmrService().scan(onProgress: ..., title: ...)`.
3. Progress UI driven by `OmrScanStage` (`capturing` → `preprocessing` →
   `cropping` → `segmenting` → `detecting` → `recognising` → `assembling`) —
   a simple stepper or progress label is enough. The on-device pipeline takes
   up to ~15s, so a progress indicator matters.
4. On `null` result (user cancelled scan or crop): pop back, no error.
5. On success: `PieceRepository.savePiece(title, musicXml)`, then navigate to
   the piece detail/practice screen (reuse existing fixture-piece navigation).
6. On `OmrException`: error dialog with retry — don't crash. The on-device
   pipeline can fail on poor scans (known failure modes documented in
   `homr_flutter`'s `docs/omr_evaluation/remaining_issues.md`, e.g.
   spine-fold clef clipping).

Entry point: add a "Scan a page" action to the piece list / home screen
(FAB or app-bar action).

### 1.4 Verification

- Manual end-to-end test on a physical device: scan a known Suzuki Book 1 page
  (Lightly Row — the cleanest 0%-SER case), confirm the imported piece plays
  back correctly (staff view + jianpu/fingering + MIDI playback) and matches
  the gold-standard note count.
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

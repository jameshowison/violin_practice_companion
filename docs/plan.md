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

**§6 Note editing for scan corrections** is now implemented (6.1–6.8): the
data model (`DurationStep`, `KeySignature`, extended `NoteEvent.copyWith`,
`ParsedPiece` timing fields + `Measure.isDurationMismatch` +
`flaggedMeasureNumbers`), MusicXML mutation (`MeasureXmlEditor`), storage
passthrough (`updateScannedPiece`), beat-count flagging glyph in
`MeasureSelector`, the `MeasureEditRow` widget, the `EditMeasureScreen`, and
the "Edit" button wired into both `_ActiveMeasureSelector` call sites. Unit
tests pass (duration/key-signature/round-trip/flagging) and the app compiles
and runs on the iPhone 17 simulator with the Edit button correctly gated off
for read-only fixture pieces. **Remaining (device-only, needs a scanned
piece):** exercise the full edit flow on a real scanned piece — live OSMD
preview updates, the flag banner re-evaluating as notes change, and that a
saved edit survives an app restart. See §6 Verification below.

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

## 2. Measure selection UX — reworked (done)

**Track C** originally proposed polishing the bottom-tray tile strip
(`MeasureSelector`) for discoverability + range selection. Instead, selection
was **moved onto the notation itself** and the tile strip removed. Now:

- **Tap-to-select on every view** — staff, jianpu, and fingering. The tray
  `MeasureSelector` is gone (`measure_selector.dart` deleted); `SectionBar`
  stays for whole-section ranges.
- **Range = "tap anchor, tap to extend"** (plan §2 C2 semantics), centralized
  in the pure, unit-tested `MeasureSelection.afterTap(current, tapped)` in
  `providers.dart`, used by all views via `_NotationView._selectMeasure`
  (`test/measure_selection_test.dart`). No drag — it never fights the staff
  WebView's vertical scroll.
- **Floating "Edit m. N" button** (`_FloatingEditButton`) overlays the notation
  whenever a single editable measure is selected (replaces the old tray-bound
  button; independent of drawer state).
- **Flagged-measure (beat-count) warnings** render on the staff (SVG marker)
  and on jianpu/fingering cells, since the tray glyph was removed.

**Staff bridge ↔ OSMD addressing.** `osmd_bridge.html` exposes tap detection
(`measureTapped`), `setSelection`, and `setFlaggedMeasures`, and draws snug
per-measure highlight rects (the *draw* box uses each measure's own staff
bounding box so it tracks staff-spacing; the *tap* hit-band uses the full
system row so short measures stay tappable). **Crucially the bridge addresses
measures by POSITIONAL INDEX, not OSMD's `MeasureNumber`** — OSMD renumbers a
short first measure as an anacrusis (0), diverging from our parsed model's
numbering. `StaffView` maps index ↔ model number via a `measureNumbers` list
(`parsed.measures.map((m) => m.number)`); the `-1` start = "no selection"
sentinel (0 is a valid index).

**Platform status: iOS first, web later.** Selection *highlighting*
(Dart→HTML) works on both. Tap *origination* (HTML→Dart) is wired only on the
iOS `webview_flutter` variant via the `OsmdBridge` JS channel; the web iframe
return channel is deferred. On web, in Staff modes, selection is set via
jianpu/fingering taps or `SectionBar` until that lands.

**Known Marionette limitation:** synthetic taps don't reach the native
WKWebView, so on-staff tap-to-select can't be driven by Marionette — verify
real staff taps in the simulator directly (the rest is auto-verifiable).

### Pickup / measure-numbering correctness (done)

Pieces with an anacrusis exposed several off-by-ones, now fixed:
- **Playback range** (`playback_service_base.dart`) mapped `fromMeasure - 1`
  as an array index — wrong whenever a pickup shifts `Measure.number` vs the
  positional index. `MidiData` now carries `measureNumbers` + `indexOfMeasure`;
  start/end resolve through it (`test/midi_generator_test.dart`).
- **Pickup never flagged** — `flaggedMeasureNumbers` excludes `number == 0`
  *and* a short first measure (OMR output often numbers a pickup `1`, not `0`).
- **Edit screen** loads the measure by `.number` (not `measures[n-1]`).

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

---

## 6. Note editing for scan corrections (implemented — device verification pending)

OMR (homr) gets scanned pieces close to perfect (17/18 perfect on the Suzuki
Book 1 evaluation set, see `docs/explore.md` §4.4), but "close" still means a
user occasionally needs to fix one or two notes — a wrong pitch, a wrong
duration, a missing/extra accidental, or (less often) a measure that was
rhythmically mis-segmented so it has the wrong number of notes. Right now
there's no way to correct a scanned piece short of re-scanning, which doesn't
fix systematic misreadings.

This adds an in-app note editor reachable from the existing single-measure
selection (the same selection already used to set the playback range), scoped
to one measure at a time, with a live single-measure staff preview so
duration/pitch changes are seen as real engraved notation rather than text.
Editing only applies to scanned pieces (`Piece.musicXmlFilePath != null`);
bundled fixture pieces remain read-only.

**Explicitly out of scope for v1**: cross-measure ties, multi-voice/chords/
repeats, and beam regeneration (edited eighth/sixteenth notes render
unbeamed/flagged — cosmetically different but musically correct). Measures
with the wrong total duration are auto-flagged but not auto-fixed.

**Known gap:** an *empty* measure (e.g. homr's `<measure number="9"/>` in
`homr_15_minuet_no_3.xml`) has no note to select, so the current editor (whose
insert/delete act on a selected note) can't add the first note. It's flagged,
but fixing it needs an "add note to empty measure" affordance.

### Proposed UI

**Entry point — reuse existing measure selection.** `_toggleMeasure` /
`MeasureSelector` already produce a single-measure `MeasureSelection(m, m)`
used for playback range. When exactly one measure is selected **and** the
piece is editable (`musicXmlFilePath != null`), an "Edit measure" button
appears next to the measure selector in the bottom tray
(`_ActiveMeasureSelector` in `piece_detail_screen.dart`). Flagged measures
(wrong total duration) get a small warning glyph on their tile.

```
┌──────────────────────────────────────────────────────────────────┐
│  Staff │ Staff+Finger │ Jianpu │ Fingering        ← mode tabs      │
├──────────────────────────────────────────────────────────────────┤
│  ── Section A ──────────────────────────────────                  │
├──────────────────────────────────────────────────────────────────┤
│ ┌──┐┌──┐┌──┐┏━━━━┓┌──┐┌──┐┌──┐┌──┐┌──┐┌──┐        ┌─────────────┐ │
│ │1 ││2 ││3 │┃ 4 ⚠┃│5 ││6 ││7 ││8 ││9 ││10│        │ ✎ Edit m. 4 │ │
│ └──┘└──┘└──┘┗━━━━┛└──┘└──┘└──┘└──┘└──┘└──┘        └─────────────┘ │
│              ▲ selected + flagged (5 beats found, expected 4)     │
├──────────────────────────────────────────────────────────────────┤
│              ▶  (existing playback controls)                      │
└──────────────────────────────────────────────────────────────────┘
```

**Edit screen — single measure, landscape-oriented.** Pushed full-screen via
`Navigator.push`. Designed for landscape (rotate phone) to give the note row
breathing room.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ✕ Cancel                  Edit Measure 4 of 12                  Save ✓    │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│                  ♩    ♪♪    ♩.    ♩       ← live OSMD preview              │
│                  D5   E5 F#5 G5.   A5        (this measure only,           │
│                                               re-rendered after each edit)  │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────┤
│ ⚠  Measure totals 5 beats — expected 4                                     │  (only if flagged)
├──────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌──────┐   ┌──────┐   ┏━━━━━━┓   ┌──────┐   ┌──────┐                    │
│   │  D5  │   │  E5  │   ┃ F♯5  ┃   │ G5 •  │   │ rest │                    │
│   │  ♩   │   │  ♩   │   ┃  ♩   ┃   │  ♩    │   │  ♩   │                    │
│   │  A2  │   │  A3  │   ┃  A4  ┃   │  A0   │   │      │                    │
│   └──────┘   └──────┘   ┗━━━━━━┛   └──────┘   └──────┘                    │
│                            ▲ selected note                                  │
├──────────────────────────────────────────────────────────────────────────┤
│  PITCH        ACCIDENTAL        DURATION                NOTE / MEASURE     │
│  ┌─────┐      ┌───┬───┬───┐     ┌──────┬──────┐         ┌────────────┐    │
│  │  ▲  │      │ ♭ │ ♮ │ ♯ │     │  ◀   │  ▶   │         │  ⇄ rest    │    │
│  ├─────┤      └───┴───┴───┘     │shorter│longer│         ├────────────┤    │
│  │  ▼  │                        └──────┴──────┘         │ + insert   │    │
│  └─────┘                          "quarter note"        │ − delete   │    │
└──────────────────────────────────────────────────────────────────────────┘
```

**Interaction model:**

- **Tap a note card** to select it (highlight border, like `F♯5` above).
  Controls are disabled until a note is selected.
- **Pitch ▲ / ▼** — moves the note one *staff position* (diatonic step:
  C-D-E-F-G-A-B, wrapping octave on B↔C). The new note's accidental resets to
  the key signature's default for that letter (e.g. in D major, F defaults to
  F♯). This matches "shift location on staff" — the user dials the notehead
  to the line/space that matches the printed page.
- **Accidental ♭ / ♮ / ♯** — overrides `alter` to −1/0/+1 for the selected
  note regardless of the key-signature default (handles "extra/missing
  accidental" errors). Resets to the key default whenever pitch ▲/▼ is
  pressed again.
- **Duration ◀ / ▶** — cycles through a single ordered list combining note
  value *and* dot, from shortest to longest: `16th, 16th•, 8th, 8th•,
  quarter, quarter•, half, half•, whole, whole•`. ◀ = shorter, ▶ = longer —
  directly matches "left/right for longer/shorter" without a separate dot
  toggle.
- **⇄ rest** — toggles the selected note between a pitched note and a rest
  (preserving its duration).
- **+ insert** — inserts a copy of the selected note immediately after it
  (default: same pitch, quarter note); user then adjusts pitch/duration.
  Handles "OMR merged two notes into one."
- **− delete** — removes the selected note from the measure. Handles "OMR
  split one note into two" or any extra note.
- The flagged-measure banner re-evaluates live as notes are edited, so the
  user gets immediate feedback on whether the measure now totals correctly.
- **Save** re-serializes just this measure back into the piece's MusicXML
  file and returns to the piece detail screen (which re-parses and
  re-renders all views). **Cancel** discards in-screen edits.

### Implementation plan

**6.1 Data model**

- `lib/models/note_event.dart`
  - Extend `copyWith()` to also accept `pitch`, `octave`, `midiNumber`,
    `noteValue`, `dotted`, `isRest` (currently only jianpu*/finger* fields are
    covered).
  - Add a `lib/models/duration_step.dart` with the ordered
    `(NoteValue, dotted)` list above and `next()`/`previous()` helpers
    (clamped at the ends, not wrapping). Shared by the duration control and
    by serialization (`<duration>` = divisions × beat-length).
  - Add a key-signature accidental-default helper (e.g. static method on
    `ParsedPiece` or `lib/models/key_signature.dart`): given `keyFifths` and
    a step letter, return the default alter using the standard sharp order
    `F C G D A E B` / flat order `B E A D G C F`.

- `lib/models/parsed_piece.dart`
  - Add `divisions`, `beatsPerMeasure`, `beatType` to `ParsedPiece`
    (currently absent — needed for `<duration>` generation and beat-count
    validation). Thread through `copyWithMeasures`.
  - Add `Measure.isDurationMismatch(beatsPerMeasure, beatType)` — sums
    `notes` (excluding `hiddenLeadNotes`) in beat units and compares to
    expected; always `false` for measure 0 (pickup).
  - Add `ParsedPiece.flaggedMeasureNumbers` (`Set<int>`) convenience getter.

- `lib/services/musicxml_parser.dart`
  - Read `<divisions>` and `<time><beats>/<beat-type>` from the first
    `<attributes>` block (same `findAllElements` pattern already used for
    `<key>`), populate the new `ParsedPiece` fields.

**6.2 MusicXML mutation/serialization**

New file `lib/services/measure_xml_editor.dart` (sibling to
`fingering_xml_injector.dart`, same parse/mutate/`toXmlString()` pattern —
not extended from the injector since it rewrites note lists rather than
annotating existing ones):

- `buildNoteElement(NoteEvent note, int divisions)` → `<note>` XML: `<pitch>`
  (reuse the step/alter/octave regex already in
  `palette_xml_generator.dart`'s `_parsePitch`) or `<rest/>`, `<duration>`
  from `noteValue`/`dotted`/`divisions`, `<type>`, optional `<dot/>`,
  `<fingering>` if `scoreFinger` set.
- `replaceMeasureNotes(String musicXml, int measureNumber, List<NoteEvent> notes, int divisions)`
  → parse, find `<measure number="$measureNumber">`, remove only its
  `<note>` children (preserving `<attributes>`/`<print>`/`<barline>` etc.),
  insert newly-built `<note>` elements, re-serialize.
- `buildSingleMeasurePreviewXml(String originalMusicXml, int measureNumber, List<NoteEvent> notes, ParsedPiece parsed)`
  → minimal `<score-partwise>` with one `<part>`/`<measure number="1">`
  containing a synthesized `<attributes>` (divisions/key/time/clef from
  `parsed`) followed by the edited notes. **This exact shape
  (`<part-list><score-part id="P1"><part-name/></score-part></part-list>` +
  one part/measure with `<attributes>`) is already proven to work with
  `StaffView`/OSMD** — `palette_xml_generator.dart` generates the same
  structure and is rendered live today via the `_PalettePanel`'s `StaffView`
  with `bridgeAsset: 'assets/osmd/palette_bridge.html'`. Low risk.

**6.3 Storage**

- `lib/services/piece_storage_io.dart`: add
  `Future<void> updateScannedPiece(String musicXmlFilePath, String newMusicXml) => File(musicXmlFilePath).writeAsString(newMusicXml)`.
- `lib/services/piece_storage_web.dart`: stub throwing `UnsupportedError`
  (consistent with the existing OMR-unavailable-on-web stance).
- `lib/services/piece_repository.dart`: add a passthrough
  `updateScannedPiece(...)` (mirrors the existing `savePiece` →
  `saveScannedPiece` passthrough).

**6.4 Beat-count flagging**

- `MeasureSelector` (`lib/widgets/measure_selector.dart`): add an optional
  `Set<int>? flaggedMeasures` param; render a small warning glyph on flagged
  tiles.
- `piece_detail_screen.dart`: pass `parsedPiece?.flaggedMeasureNumbers` into
  both `_ActiveMeasureSelector` instances (full layout and compact tray).

**6.5 New edit-row widget**

New `lib/widgets/measure_edit_row.dart`:
- `MeasureEditRow` — horizontal row of `_NoteEditCard`s for the single
  measure being edited (no scrolling needed in landscape for
  Suzuki-Book-1-length measures).
- `_NoteEditCard` — shows pitch+accidental, a duration glyph/label, and the
  fingering label if present (rendered verbatim per the fingering-label
  rule). ~72×96pt cards — generous touch targets, distinct from the
  jianpu/fingering views' 36px playback-tuned cells. Selected state uses a
  bold border (visually distinct from the amber playback-highlight
  convention, since this is an edit-time selection, not a playback position).

**6.6 Edit screen**

New `lib/screens/edit_measure_screen.dart`:
- `EditMeasureScreen` (`ConsumerStatefulWidget`), takes a `measureNumber`.
  Local state: `List<NoteEvent> _notes` (seeded from
  `parsedPiece.measures[measureNumber - 1].notes`), `int? _selectedIndex`.
  No new Riverpod provider — edit-in-progress state is ephemeral and
  screen-local.
- Layout (landscape `Scaffold`): `AppBar` (Cancel / title / Save) →
  `SizedBox(height: ~120)` with `StaffView(musicXml: _previewXml, bridgeAsset: 'assets/osmd/palette_bridge.html')`
  → conditional warning banner → `MeasureEditRow` → control panel row.
- `_previewXml` recomputed via `buildSingleMeasurePreviewXml` in `setState`
  after every edit; `StaffView` already re-posts `loadScore` when `musicXml`
  changes (used today for mode/spacing changes), so live updates are "free."
- **Save**: `MeasureXmlEditor.replaceMeasureNotes(originalXml, measureNumber, _notes, parsed.divisions)`
  → `pieceRepository.updateScannedPiece(piece.musicXmlFilePath!, newXml)` →
  `ref.invalidate(parsedPieceProvider)` → `Navigator.pop()`.

**6.7 Integration into `piece_detail_screen.dart`**

- Add the "Edit measure" button next to `_ActiveMeasureSelector` in both the
  full layout and compact tray. Gating condition:
  `selection != null && selection.startMeasure == selection.endMeasure && piece.musicXmlFilePath != null`
  — no `kIsWeb` check needed, since `musicXmlFilePath` is only ever non-null
  on platforms where scanning/editing is supported (clean per the
  multi-platform smell-check).
- `onPressed: () => Navigator.push(..., EditMeasureScreen(measureNumber: selection.startMeasure))`.

**6.8 Testing**

- Extend `test/musicxml_parser_test.dart`: assert new `divisions` /
  `beatsPerMeasure` / `beatType` fields parse correctly from the existing
  `simpleXml` fixture.
- New `test/measure_xml_editor_test.dart`: round-trip — build `NoteEvent`s →
  `buildNoteElement`/`replaceMeasureNotes` → re-parse with
  `MusicXmlParser` → assert pitch/octave/duration/dot/rest/fingering survive.
  Also assert `buildSingleMeasurePreviewXml` output is valid XML
  (`XmlDocument.parse` doesn't throw) with the expected `<attributes>`.
- New `test/duration_step_test.dart`: cycling order and clamping at both
  ends.
- New `test/key_signature_test.dart`: default-accidental lookups for a couple
  of keys (e.g., D major → F defaults sharp; C major → no defaults).
- New test for `Measure.isDurationMismatch`: true/false cases, and confirm
  measure 0 (pickup) is never flagged.

### Verification

1. Run the new unit tests (`flutter test`).
2. On the iPhone 17 simulator, open a scanned piece, select a single
   measure, confirm the "Edit measure" button appears (and does *not* appear
   for bundled fixture pieces).
3. Open the edit screen in landscape; confirm the live OSMD preview renders
   the single measure and updates after a pitch/duration/accidental/insert/
   delete edit.
4. Deliberately edit a measure to have the wrong number of beats; confirm the
   warning banner appears/disappears live as edits change the total.
5. Save an edit, confirm the piece detail screen's staff/jianpu/fingering
   views all reflect the change, and that the change survives an app
   restart (re-reads the rewritten `.musicxml` file via `index.json`).
6. Use Marionette to screenshot the surrounding edit-screen chrome (note: the
   live OSMD preview itself will render blank in Marionette screenshots per
   the known WebView limitation — verify the preview visually in the
   simulator window directly).

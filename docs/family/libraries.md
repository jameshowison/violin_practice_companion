# Product-line libraries: what to spin off, and in what order

Status: proposal, 2026-11-19. Nothing here is built. It goes with
[`approach.md`](approach.md), which describes the family of apps these
libraries serve.

## Principles

1. **Extract what is already nearly clean.** Most of the MusicXML and
   alignment code is pure Dart today. Start with that, not with the tangled
   widget.
2. **No app glue in a library.** No Riverpod, no `shared_preferences`, no
   `rootBundle` reads hidden inside a library, and no app models. Tables and
   assets are passed in; storage stays in the app.
3. **Tests move with the code.** Each extraction carries its existing tests,
   and Stringlings keeps passing `flutter test` after every step.
4. **Follow the precedent already in the repo.**
   - First as a **path dependency** under `packages/`, like
     `packages/string_tuner`: `publish_to: none`, its own `test/`, README,
     CHANGELOG and LICENSE.
   - It stays in this repo, a member of the pub workspace, even after a second
     app uses it (Decisions, below). A repo of its own, pinned by tag the way
     `homr_flutter` is, comes only if outside users appear.
5. **Not too many.** Six public libraries and one internal core. Each one has
   to earn its place by being useful outside the family.

## The libraries

| # | Library | Kind | ≈ size | Value outside the family |
|---|---|---|---|---|
| 1 | `musicxml_tools` | pure Dart | 5–6.5k lines | High. Repairing noisy OMR MusicXML, plus an editor |
| 2 | `score_view` | Flutter | ~6k | High. Interactive Verovio in Flutter: tap to measure, cursor, selection |
| 3 | `homr_flutter` (existing) + `homr_capture` | Flutter | +0.8k | Already public |
| 4 | `score_sync` | pure Dart | ~2k | High. Score↔recording alignment in pure Dart |
| 5 | `audio_decoder` | federated plugin | ~0.7k | Medium. Any file to mono float PCM at the native rate |
| 6 | `pitch_tuner` (rename of `string_tuner`) | pure Dart | ~1k | Medium. YIN, a tracker and tuning targets |
| — | `practice_core` | internal | large | Family only |

### 1. `musicxml_tools` (pure Dart; `xml`, `meta`)

**Contents:**

- **Model:** `NoteEvent`, `ParsedPiece`, `DurationStep`, `KeySignature`
  (`lib/models/`).
- **Parser:** `musicxml_parser.dart`.
- **Editor:** `measure_xml_editor.dart` (1287 lines).
- **OMR repairs.** Each is a `String → String` transform with no instrument
  logic:
  - `bar_rest_repair`
  - `meter_repair`
  - `tuplet_repair`
  - `musicxml_normalizer`
  - `musicxml_consistency`
  - `musicxml_beamer`
- **Injectors and generators:**
  - `chord_xml_injector`
  - `lyric_xml_injector`
  - `fingering_xml_injector` (the placeholder that reserves Verovio's lane)
  - `preamble_xml_generator`
  - `palette_xml_generator`
- **Interchange:**
  - ABC export (`abc_exporter.dart`, pure)
  - ABC import: the Dart side of `abc_converter*` (≈120 lines) plus the two JS
    assets, with a JS loader passed in (it runs under `flutter_js`, so this
    part is an optional Flutter sub-library)
  - Jianpu (`jianpu_converter.dart`, with its key table passed in rather than
    read via `rootBundle` at :9)
- **Second tier, after `Section` is generalized:**
  - `system_break_injector`
  - `engraved_measure_map`
  - `chord_editor`
  - `tuplet_editor`

**Blockers:**

- **`NoteEvent` carries app and violin fields:**
  - `DisplayMode` (`note_event.dart:35`)
  - `jianpuNumber`/`jianpuOctaveDots` (:106-107)
  - `fingerString`/`fingerNumber` (:111-112)

  Move them to a side map keyed by note (or an app-side extension type), so
  the library's note is musical only. This is also the seam where
  `InstrumentProfile.annotator` output lands.
- **`Section`** (label, start measure, start note) is a practice-app idea that
  the break injector and measure map depend on. Generalize it into a neutral
  `MeasureMarker`; sections and **student notes** (`approach.md`, Annotate)
  are then both markers.
- **`measure_xml_editor.dart:391`** imports Flutter only for
  `@visibleForTesting`. Use `package:meta`.
- **For Annotate:** editor operations return a **bar mapping** (old index →
  new index, or deleted), so callers can remap markers after an edit.
- **Later (needed by `approach.md` Part 2):** read `<transpose>` and `<clef>`,
  and model parts, staves and voices instead of concatenating every part's
  measures (`musicxml_parser.dart:52`). That is the biggest change this
  library will see; keep the single-line API as a view over the new model.

**Tests that move:** `musicxml_parser_test`, `measure_xml_editor_test`,
`musicxml_normalizer_test`, `musicxml_consistency_test`, `musicxml_beamer_test`,
`bar_rest_repair_test`, `abc_exporter_test`, `abc_to_musicxml_test`,
`jianpu_converter_test`, and others like them. Tests that use restricted
fixtures (`test/support/restricted_fixtures.dart`) need the same skip-without
mechanism in the package.

### 2. `score_view` (Flutter; `verovio_flutter`, vendored `jovial_svg`)

**The engraving layer** is Flutter only through `dart:ui`, with no Riverpod:

- `verovio_engraver.dart` (1889 lines). `engrave()` returns an `EngravedScore`
  with the SVG, bounding boxes, measure and note anchors, line bands, and
  `measureAt`/`noteAt`. **That is already the tap-to-measure hit map.**
- `staff_zoom`, `section_line_planner`, `section_engraving` and
  `print_paginator`.
- `engrave_disk_cache_io`, with its cache key passed in instead of importing
  `build_info.dart`.

**The widget layer** is `widgets/staff_view_verovio.dart` (3461 lines), plus
`measure_drag_select` and the bits of `ui/adaptive` it uses.

**Public API sketch:**

```
ScoreView(
  score: EngravedScore | musicXml + engraver,
  layout: ScoreLayoutOptions(size, spacing, measuresPerLine, linesPerSection, insets),
  cursor: ValueListenable<ScoreCursor?>,      // (measure, note)
  selection: MeasureRange?, onMeasureTapped, onMeasureRange, onNudge…, 
  tints:  List<MeasureTint>,                  // sections, flagged bars
  lanes:  List<LaneLabel>,                    // annotator labels, chords, NOTE MARKERS
  onMarkerTapped, onContentHeight,
)
```

**Blockers:**

- **It reads 8 providers:**
  - `staffSize`
  - `staffSpacing`
  - `fitTooLong`
  - `effectiveMeasuresPerLine`
  - `effectiveLinesPerSection`
  - `staffViewBottomInset`
  - `notationBottomClearance`
  - `activePlaybackState`, through `ref.listen`

  All become parameters or callbacks.
- **It imports app types:**
  - the violin string palette
  - the section and chord palettes
  - `fingering_annotation_builder`, which uses GDAE
  - `midi_generator`'s `HighlightEvent`
  - `PlaybackState`

  These become the generic `tints`/`lanes`/`cursor` types above.
- **`score_printer.dart` imports the widget**, an upward edge. Split the PDF
  layout from the widget, and ship printing as an optional part
  (`score_view/pdf.dart`).

This is the **biggest refactor** in the plan. Do it when a second app actually
needs the widget, not before. The engraving layer can move earlier on its own.

### 3. Scanning: `homr_flutter` (existing) + optional `homr_capture`

Recognition already lives in homr_flutter. What the app adds:

- **Title OCR** (`title_recognizer_io`, `title_region`, ≈400 lines). Move it
  into homr_flutter; it already exports `TextReader`.
- **The repairs.** They go to `musicxml_tools` (above), where non-OMR users
  benefit too.
- **Capture** (`omr_service_io.dart`): the document scanner, photos, files,
  PDF rasterizing and cropping. That is ≈370 lines of plugin wiring. Package
  it as `homr_capture` only if a second app wants a different flow; otherwise
  it lives in `practice_core`.

The models stay in each app's assets, never in the package (CLAUDE.md).

### 4. `score_sync` (pure Dart; `fftea`, `wav`)

**Contents:**

- **`ScoreTimeline`**, a new interface: notes (pitch, onset, duration),
  measure onsets and numbers, total duration, at a tempo. It replaces the
  aligner's reach into `ParsedPiece` and `MidiGenerator`; the app adapts its
  model to it.
- **`ScoreAudioAnchor`** (score ms ↔ audio s) and its JSON codec. The
  persistence (`media_alignment_store`, `shared_preferences`) stays in the
  app.
- **Count-in math** (`models/count_in.dart`, pure).
- **Alignment:**
  - `audio_chroma_features`, `chroma_vector`, `score_chroma_reference`
  - `dtw_align`
  - `audio_score_auto_aligner`, with its post-passes (`refineAtNoteChanges`,
    `restsAbsorbPauses`, `hasCompressedRun` and the rest)
  - `audio_energy_envelope`
- **An isolate-friendly entry point.** Alignment runs on the UI isolate today
  (`media_playback_service.dart`).
- **Calibration click-pattern matching** (`sync_calibration.dart`, foundation
  only).
- **Later:** the offline score renderer from `docs/rendered-score-plan.md`,
  whose anchors are written at render time. Its GM program must be a
  parameter, not `midi_patch.json["violin"]`.

**Blockers:**

- `MidiGenerator` imports `rootBundle` for one constant,
  `ticksPerQuarterNote` (`midi_generator.dart:2,106`). Pass it in.
- The user-facing review string belongs in the app.
- **Per-instrument parameters become a public `AlignmentProfile`.** Today:
  - the chroma band is 180–2600 Hz (`audio_chroma_features.dart:108-109`)
  - `ringSeconds = 1.0` (`score_chroma_reference.dart:38`)
  - `onsetWeight` (`dtw_align.dart`)

  Low strings, low brass, winds and flute each need other values
  (`approach.md` Part 2).

**Tests that move:** `dtw_align_test`, `audio_chroma_features_test`,
`score_chroma_reference_test`, `audio_score_auto_aligner_test`,
`synthetic_alignment_robustness_test`, and the per-piece alignment regression
tests. Several of those use restricted recordings, and must skip without them,
as now.

### 5. `audio_decoder` (federated plugin)

- **Dart:** `audio_decoder_base.dart` (pure, `PcmAudio`) and
  `audio_decoder_io.dart`.
- **iOS:** `ios/Runner/AudioDecoderPlugin.swift` (AVFoundation).
- **Android:** `AudioDecoderPlugin.kt` (MediaCodec, including the SBR
  sample-rate fix).
- **What it does:** decodes any audio or video file to mono Float32 at the
  source rate. Rate errors scale every alignment anchor, which is why this is
  worth getting right once and sharing.
- **Blockers:**
  - `shrinkVideo` shares the channel (and on iOS, the Swift file). Split it
    into its own app-level plugin.
  - Channel names carry the `violin_practice_companion/` prefix.
  - It is hand-registered in `AppDelegate.swift` and `MainActivity.kt`, so
    packaging it as a federated plugin is new work.

### 6. `pitch_tuner` (rename of `packages/string_tuner`; pure Dart)

**Already a package:**

- range-limited YIN (`yin.dart`)
- a streaming tracker (`pitch_tracker.dart`)
- `InstrumentTuning` with violin, viola, cello and mandolin presets
  (`tuning.dart:52-68`)

**Grows into:**

- **Targets:** open strings (N-string, re-entrant allowed), **chromatic**, or a
  single target note.
- **Transposition:** shows written pitch for B♭/E♭/F instruments.
- **A sustained-tone segmenter**, generalized from `TunerModel`
  (`services/tuner_model.dart`), whose onset, attack and decay rules are tuned
  for plucks and bows.
- **An advice interface.** Today's peg advice (`tuner_advice.dart`) is the
  strings implementation.
- **Settings:** frame length and clarity threshold (tuba needs longer frames;
  flute's breathy tone needs a lower clarity threshold).
- **Extras:** `unison_meter.dart` (mandolin courses) moves in as an extra.

**Stays in the app:** `tuner_input*` (the `record` plugin, Riverpod) and the
screen.

### — `practice_core` (internal, not promoted)

The family's real reuse is app-shaped, and that is fine to keep private to
the family. It contains:

- library, catalog (with `instruments` tags) and repository
- the storage façades (`*_io.dart`)
- the share bundle and the dev library
- `PlaybackService`
- `NativeTransport`, with the iOS transport, route and calibration plugins
  (`VideoTransportPlugin.swift`, `AudioRoutePlugin.swift`,
  `AudioCalibrationPlugin.swift`, with their `app_audio_session` coupling)
- `ui/adaptive`
- `InstrumentProfile` and the registry of profiles
- **the student-notes store:** the `notes.json` sidecar, anchor remap after
  edits, share and dev-library sync (`approach.md`, Annotate)

It becomes a package when the monorepo appears (step 5 below). Until then it
*is* Stringlings.

### Deliberately not libraries

- **Student notes (Annotate).** These are an app feature built from three
  library capabilities:
  - `MeasureMarker` and the bar mapping, in `musicxml_tools`
  - the marker lane, in `score_view`
  - the store, in `practice_core`
- **ABC import as its own package.** It is too small; it is a sub-library of
  `musicxml_tools`.
- **Teacher-video capture and the video shrinker.** They are app-level; the
  Dart orchestration is tied to `PieceMedia`.
- **A practice-playback scheduler package.** If the rendered-score plan lands,
  playback becomes "everything is a recording plus anchors", and the live
  scheduler shrinks. Revisit after that.

## Order

Each step leaves Stringlings shipping, with its tests passing, and is useful
even if the family never happens.

1. **`musicxml_tools` (first tier) and `score_sync`.** Both are pure Dart,
   lowest risk and easy to test, and they force the clean `NoteEvent` and
   `ScoreTimeline` seams.
2. **`InstrumentProfile` inside Stringlings,** proved with **viola**, on the
   source/instrument/player layers of [`layers.md`](layers.md): alto
   clef, a different tuning, and no second app.
   - **2a. Annotate in Stringlings:** text notes and stamps, then voice notes.
     It is useful to violin families right away, and it pulls `MeasureMarker`
     and the marker lane ahead of step 4. Mock the UI in an artifact first.
3. **`pitch_tuner`** (chromatic mode, transposition), then **transposition**
   and `<clef>` in `musicxml_tools`. Together these unlock a woodwind
   prototype: recorder or flute, then clarinet.
4. **`score_view` without Riverpod,** done when the second app actually needs
   it.
5. **`audio_decoder` as a federated plugin,** then **`practice_core`,** then
   the **monorepo** (Dart pub workspaces) with thin app targets per family.
6. **Later:** parts, staves and voices, for guitar and piano.

## Licensing

The family's own libraries are **GPL-3.0**, like the app. What they combine
with:

| Component | Licence | Combines with GPLv3? | Note |
|---|---|---|---|
| `homr_flutter` (ours) and homr's models | **AGPL-3.0** | Yes (GPLv3 §13 allows combining with AGPLv3) | Any app that links it is effectively under AGPL terms. Harmless for an offline app; matters only to someone building a network service on it |
| `packages/string_tuner` (ours) | **BSD-3-Clause** | Yes | Decide whether it becomes GPL as `pitch_tuner`, or stays permissive to be more widely useful |
| `verovio_flutter` (third party, 0.3.1) | LGPL-3.0 | Yes | Also has an xml version override in our pubspec |
| `jovial_svg` (vendored, patched) | BSD-3-Clause | Yes | Drop the vendored copy once upstream fixes font-family |
| abcjs | MIT | Yes | Bundled JS |
| GeneralUser GS soundfont | its own licence (`assets/engine/licenses/generaluser_gs.txt`) | Bundled as data | Every new GM program needs a re-cut |

## Decisions (2026-11-20)

The four open questions, settled:

1. **Licences:** the family's libraries are **GPL-3.0**. `string_tuner`
   stays **BSD-3-Clause** when it is renamed `pitch_tuner`, so the small DSP
   core stays useful to anyone.
2. **Repo layout:** **one monorepo**, as a Dart pub workspace. The app stays at
   the root until a second app exists (step 5), then moves to `apps/`.
3. **Public home:** the maintainer's own GitHub account, next to homr_flutter.
   A transfer to an organization later keeps redirects.
4. **pub.dev:** **not yet.** The libraries are path dependencies inside the
   monorepo. Revisit for `musicxml_tools`, `score_sync` and `pitch_tuner` once
   an API has held still through a second app.

Also decided:

- `pitch_tuner` is kept, even though winds and brass rarely tune before
  practice: chromatic mode and written pitch serve their long-tone and
  intonation work.
- `pitch_tuner` gains a **drone mode**, which sounds the target pitch for
  tuning by ear. The tone is generated as a loopable buffer and played as a
  file, never a live synth (CLAUDE.md, "Audio on iOS").

How each step is carried out, and the checklist for every extraction:
[`../libraries-migration.md`](../libraries-migration.md).

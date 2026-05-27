# Phase 2: MIDI Playback + Teacher Video

## Prerequisites

Phase 1 complete. Specifically, the following contracts from Phase 1 are assumed
stable and must not change:

- `ParsedPiece` and `NoteEvent` data models
- `MusicXmlParser` service interface
- `MeasureSelector` emitting `MeasureSelection(startMeasure, endMeasure)`
- Lookup table structure in `assets/lookup_tables/`

## Goal

Add MIDI playback with tempo control, a visual playback indicator (bouncing
ball or measure highlight), section loop practice, teacher video import, and
on-device audio-to-score alignment. All processing remains fully offline.

---

## Additional Stack

| Concern | Choice |
|---------|--------|
| MIDI generation | `dart_midi` package (or minimal custom writer) |
| SoundFont playback | `flutter_midi_pro` |
| SoundFont file | GeneralUser GS (.sf2, free for redistribution, ~30MB) |
| Audio extraction from video | `ffmpeg_kit_flutter` |
| FFT for chroma features | `fftea` (pure Dart) |
| DTW alignment | Custom Dart implementation (see below) |
| Video playback | `video_player` |
| File import | `file_picker` |

---

## Additional Lookup Tables

As with Phase 1: **no MIDI constants, patch numbers, or timing constants may
appear in Dart source code.** All such values live in JSON assets.

### `assets/lookup_tables/midi_patch.json`

```json
{
  "comment": "General MIDI patch assignments. Violin = program 40 (0-indexed). Edit here to try alternate patches without touching code.",
  "violin": 40,
  "ticksPerQuarterNote": 480
}
```

### `assets/lookup_tables/chroma_params.json`

```json
{
  "comment": "Parameters for chroma feature extraction. sampleRate: Hz of extracted audio. frameSize/hopSize: FFT window and hop in samples. minMidi/maxMidi: clip frequency range to violin-relevant pitches only (roughly G3=55 to B5=83) before mapping FFT bins to pitch classes, preventing noise from out-of-range frequencies polluting the chroma vectors.",
  "sampleRate": 22050,
  "frameSize": 2048,
  "hopSize": 512,
  "minMidi": 55,
  "maxMidi": 83
}
```

### `assets/lookup_tables/dtw_params.json`

```json
{
  "comment": "DTW alignment parameters. bandWidthFraction: Sakoe-Chiba constraint as fraction of sequence length, preventing degenerate alignment paths on long silences.",
  "bandWidthFraction": 0.20,
  "distanceMetric": "cosine"
}
```

---

## MIDI Generation (`midi_generator.dart`)

Input: `ParsedPiece`, tempo in BPM
Output: `File` written to temp directory, `.mid` format

Reads `assets/lookup_tables/midi_patch.json` for patch number and tick
resolution.

Structure:
- Track 0: tempo map (single tempo event, microseconds per beat = 60,000,000 / BPM)
- Track 1: program change to violin patch, then note-on/note-off pairs

Note durations in ticks: derive from `NoteValue` and `ticksPerQuarterNote`:
- whole = 4 × ticks, half = 2 ×, quarter = 1 ×, eighth = 0.5 ×, sixteenth = 0.25 ×
- dotted: multiply by 1.5

Also compute and store `measureOnsetTicks: List<int>` — the tick position of
the first beat of each measure. Used by `PlaybackService` to map playback
position to measure number.

---

## Playback Service (`playback_service.dart`)

Central service managing MIDI playback state. Exposed via Riverpod provider.

```dart
abstract class PlaybackService {
  Future<void> loadPiece(ParsedPiece piece);
  Future<void> play({int fromMeasure = 1, int? toMeasure});
  void pause();
  void stop();
  void setTempo(int bpm);              // regenerates MIDI and reseeks
  Stream<int> get currentMeasure;      // emits as playback advances
  Stream<PlaybackState> get state;     // playing / paused / stopped
  bool get loopEnabled;
  set loopEnabled(bool value);
}
```

`currentMeasure` stream: driven by a timer that compares elapsed playback time
against `measureOnsetSeconds` (onset ticks converted to seconds at current BPM).
Emits when the current measure number changes.

When `setTempo` is called during playback:
1. Record current measure number
2. Regenerate MIDI at new BPM
3. Resume from the same measure number

---

## Playback Controls Widget (`playback_controls.dart`)

```
┌─────────────────────────────────────────┐
│  ◀◀   ▶ / ❚❚   ■   🔁    ♩= [====] 120  │
└─────────────────────────────────────────┘
```

- Rewind to start of selection (or piece)
- Play / Pause
- Stop
- Loop toggle (applies to selected measure range from Phase 1 `MeasureSelector`)
- Tempo slider: 40–120 BPM, default 60
- Count-in toggle: one bar of metronome clicks before playback begins

Integrated into `PieceDetailScreen` below the notation view.

---

## Visual Playback Indicator

### Measure Highlight Mode

As `PlaybackService.currentMeasure` emits:
- Highlight the active measure in the notation view (all modes)
- Scroll the notation view to keep the active measure visible
- Advance the `MeasureSelector` highlight

This mode works in all four display modes including OSMD staff view (via
`window.highlightMeasure(n)` call to the WebView).

### Bouncing Ball Mode (`bouncing_ball_overlay.dart`)

Available in jianpu, fingering, and combined modes only (not staff view).

The ball's horizontal position within a measure = fraction of measure duration
elapsed, computed from:

```
positionInMeasure = (elapsedSeconds - measureOnsetSeconds[currentMeasure])
                  / measureDurationSeconds[currentMeasure]
```

Rendered as an `AnimatedPositioned` overlay on the notation view. The ball
jumps to the left edge of the next measure on barline crossing.

The user selects indicator mode (highlight vs ball) in the settings drawer.

---

## Section Metadata Editor (`section_metadata_editor.dart`)

Accessible via an "Edit sections" button on `PieceDetailScreen`.

- Displays measure numbers as a grid
- Tap a measure to mark it as the start of a new section
- Type the section label (A, B, C... or any short string)
- Save writes a JSON sidecar to app documents directory,
  overriding the fixture default for that piece

Format matches the Phase 1 fixture sidecar format:
```json
{
  "sections": [
    { "label": "A", "startMeasure": 1, "endMeasure": 4 },
    { "label": "B", "startMeasure": 5, "endMeasure": 8 }
  ]
}
```

---

## Teacher Video (`teacher_video_service.dart`)

```dart
abstract class TeacherVideoService {
  Future<void> importVideo(String pieceId);
  bool hasVideo(String pieceId);
  bool hasAlignment(String pieceId);
  Future<AlignmentMap> getAlignment(String pieceId);
  String videoPath(String pieceId);
}
```

`importVideo`:
1. `file_picker` opens to select a video file
2. Copy to `{documentsDir}/videos/{pieceId}.mp4`
3. Trigger alignment pipeline (see below)
4. Emit progress events during alignment

File storage:
```
{documentsDir}/
  videos/
    {pieceId}.mp4
    {pieceId}_alignment.json
```

---

## Audio-to-Score Alignment

All processing on-device, runs once per video import. Target runtime: under
60 seconds on a phone from 2022 or later.

### Pipeline

```
video file (.mp4)
  → ffmpeg_kit_flutter: extract mono audio, 22050 Hz, WAV
  → ChromaExtractor: audio chroma sequence
  → ScoreChromaGenerator: score chroma sequence from ParsedPiece
  → DTWAligner: warping path
  → AlignmentMap: measure number → video timestamp (seconds)
  → save as {pieceId}_alignment.json
```

### Alignment Map Model

```dart
class AlignmentMap {
  final String pieceId;
  final Map<int, double> measureOnsets;  // measure number → seconds in video
}
```

### Chroma Extraction (`chroma_extractor.dart`)

Input: PCM audio samples (List<double>, mono, 22050 Hz)
Output: `List<ChromaFrame>` (each frame = 12 pitch-class energy values)

Uses `fftea` for FFT. All signal processing parameters are read from
`assets/lookup_tables/chroma_params.json` — no constants in Dart source.

Algorithm:
1. Frame audio into overlapping windows of `frameSize`, hop `hopSize`
2. Apply Hann window to each frame
3. Compute magnitude spectrum via FFT
4. Clip to MIDI range `minMidi`–`maxMidi` before bin mapping
   (restricts to violin pitch range, suppresses out-of-range noise)
5. Map FFT bins within that range to 12 pitch-class bins (chroma)
6. L2-normalise each chroma frame

### Score Chroma Generation (`score_chroma_generator.dart`)

Input: `ParsedPiece`, nominal BPM
Output: `List<ChromaFrame>` time-aligned to score at that tempo

For each note in the score, distribute its energy across chroma frames
proportional to its duration. Rest frames = zero chroma vector.
Output frame rate matches audio chroma frame rate (same hop/sample rate).

### DTW Aligner (`dtw_aligner.dart`)

Standard Dynamic Time Warping on chroma sequences.

Input:
- `audioChroma: List<ChromaFrame>`
- `scoreChroma: List<ChromaFrame>`
- `measures: List<Measure>`
- `scoreFrameOnsets: List<int>` — score chroma frame index of each measure onset

Output: `AlignmentMap`

All DTW parameters read from `assets/lookup_tables/dtw_params.json`.

Cost function: cosine distance between chroma frames.
Path constraint: Sakoe-Chiba band of width `bandWidthFraction` × sequence
length, preventing degenerate paths on long silences.

After computing the warping path, map each measure's score frame onset through
the path to find the corresponding audio frame index, then convert to seconds:
```
videoSeconds = audioFrameIndex × hopSize / sampleRate
```

### Alignment Progress UX

`AlignmentService` emits `AlignmentProgress` events:

```dart
enum AlignmentStage { extractingAudio, computingFeatures, aligning, saving }

class AlignmentProgress {
  final AlignmentStage stage;
  final double fraction;   // 0.0–1.0
}
```

UI shows a progress dialog with stage label and progress bar during import.
If alignment fails (e.g. too short, silent audio), show a clear error message
and allow retry.

---

## Video Playback with Score Following (`video_player_view.dart`)

When a teacher video with alignment exists for the current piece:

- "Teacher video" toggle appears on `PieceDetailScreen`
- When active, layout becomes:
  ```
  ┌─────────────────────────────────┐
  │         Teacher video           │  ← video_player, upper ~40% of screen
  ├─────────────────────────────────┤
  │     Active notation view        │  ← lower ~40%, notation follows video
  ├─────────────────────────────────┤
  │  [Section bar] [MeasureSelector]│
  │  [Playback controls]            │
  └─────────────────────────────────┘
  ```

- Playback is driven by video timestamp, not MIDI
- A `VideoPositionListener` polls `video_player`'s position stream and maps
  timestamp → current measure via `AlignmentMap`
- `currentMeasure` drives the notation highlight exactly as in MIDI mode
- Tapping a measure in `MeasureSelector` calls
  `videoController.seekTo(alignment.measureOnsets[measure])`
- MIDI playback is disabled when video mode is active

---

## Phase 2 Acceptance Criteria

- [ ] MIDI playback works for all 6 fixtures
- [ ] Tempo slider adjusts playback speed in real time without stopping
- [ ] Measure highlight advances correctly in all notation modes during MIDI playback
- [ ] Bouncing ball renders and tracks correctly in jianpu and fingering modes
- [ ] Loop playback repeats selected measure range correctly
- [ ] Count-in plays one bar of clicks before playback begins
- [ ] Section metadata editor saves and reloads correctly
- [ ] Teacher video imports and processes without crashing
- [ ] Alignment completes in under 60 seconds on a 2022-era device
- [ ] Score highlight follows video playback within ±1 measure accuracy
- [ ] Tapping a measure seeks video to the correct timestamp
- [ ] All signal processing parameters are in `assets/lookup_tables/`, not in
      Dart source code
- [ ] App remains fully offline after install — no network calls at any point
- [ ] Unit tests pass for `midi_generator`, `chroma_extractor`, `dtw_aligner`

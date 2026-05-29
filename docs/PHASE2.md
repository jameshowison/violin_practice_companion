# Phase 2: MIDI Playback

## Prerequisites

Phase 1 complete. Specifically, the following contracts from Phase 1 are assumed
stable and must not change:

- `ParsedPiece` and `NoteEvent` data models
- `MusicXmlParser` service interface
- `MeasureSelector` emitting `MeasureSelection(startMeasure, endMeasure)`
- Lookup table structure in `assets/lookup_tables/`

## Goal

Add MIDI playback with tempo control, a measure-highlight visual playback
indicator, section loop practice, and count-in. All processing remains fully
offline.

---

## Additional Stack

| Concern | Choice |
|---------|--------|
| MIDI generation | `dart_midi` package (or minimal custom writer) |
| SoundFont playback | `flutter_midi_pro` |
| SoundFont file | GeneralUser GS (.sf2, free for redistribution, ~30MB) |

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

## Visual Playback Indicator — Measure Highlight

As `PlaybackService.currentMeasure` emits:
- Highlight the active measure in the notation view (all modes)
- Scroll the notation view to keep the active measure visible
- Advance the `MeasureSelector` highlight

Works in all four display modes including OSMD staff view (via
`window.highlightMeasure(n)` call to the WebView).

---

## Phase 2 Acceptance Criteria

- [x] MIDI playback works for both fixture pieces
- [x] Tempo slider adjusts playback speed in real time without stopping
- [x] Measure highlight advances correctly in all notation modes during playback
- [x] Loop playback repeats selected measure range correctly
- [x] Count-in plays one bar of clicks before playback begins
- [x] All MIDI constants are in `assets/lookup_tables/midi_patch.json`, not in Dart source
- [x] App remains fully offline after install — no network calls at any point
- [x] Unit tests pass for `midi_generator`
- [x] Multi-platform smell check passes (no `dart:io` or `dart:html` in shared code)

# Audio-sync / teacher-demo: three next pieces of work

Written as a handoff. Each item is independently actionable; none depends on
another. All file/line references were verified against `e6591ed`.

**Background you will want first:**
[audio-sync-dtw-interior-gaps.md](audio-sync-dtw-interior-gaps.md) (the most
recent alignment work, and where items 1 and 3 came from),
[audio-sync-dtw-open-boundaries.md](audio-sync-dtw-open-boundaries.md) and
[audio-sync-dtw-anchor-compression.md](audio-sync-dtw-anchor-compression.md).

---

## 1. A teacher recording stores absolute file paths, which do not survive

**Component:** `TeacherRecordingStore`
**Files:** `lib/services/teacher_recording_store.dart`,
`lib/services/teacher_recording_capture_io.dart`,
`lib/services/teacher_recording_playback_service_io.dart`
**Severity:** a recorded demo silently stops existing — playback fails with
`PathNotFoundException`, or the video window sits empty
**Affects:** any teacher recording that outlives a change of app container

### What happens now

`teacher_recording_capture_io.dart:89-93` builds the capture paths from
`getApplicationDocumentsDirectory()`:

```dart
final docs = await getApplicationDocumentsDirectory();
final folder = Directory('${docs.path}/teacher_recordings/$pieceId');
_videoPath = '${folder.path}/video.mp4';
_audioPath = '${folder.path}/audio.wav';
```

Those **absolute** strings are then persisted verbatim
(`teacher_recording_store.dart:31-32`, read back at `:69-70`) and used
directly for playback and realignment
(`teacher_recording_playback_service_io.dart:71`, `:76`, `:90`). The documents
directory is inside the app's data container, whose path is not stable, so a
stored path can outlive the location it names.

### Evidence

Observed twice in one session on `dev-iphone`: a `flutter run` reinstall
relocated the data container (`15C986F6-…` → `72FD5DA5-…`) while prefs still
named the old one. The recording kept working only because the old directory
lingered with hardlinked files; once that window closed the app logged

```
Unhandled Exception: PathNotFoundException: Cannot open file, path =
'.../Application/15C986F6-.../Documents/teacher_recordings/galopede/audio.wav'
```

This was hit while seeding a recording by hand, but it is **not** an artefact
of seeding: iOS does not guarantee container path stability across app
updates or restores, and the same stored string is what a real capture writes.

### Suggested approach

Persist paths **relative to the documents directory** and resolve them at
load. The store already treats any parse failure as "no recording"
(`:57-60` catch → `null`), so the migration can be forgiving: if a stored
value is absolute, try it, and on failure re-resolve its last two path
segments (`teacher_recordings/<pieceId>/<file>`) against the current documents
directory. That recovers every existing recording without a schema version.

Worth noting `PieceStorage` already solved exactly this problem and documents
why — see `lib/services/piece_storage_io.dart:32-34`: *"the piece's id is its
filename, and its path is recomputed on every load"*. This is the same fix,
applied to the one store that did not get it.

### Traps

- There is **no schema version** in either prefs blob, and no hook to bump
  one. Add new fields as nullable-with-default or change the key name.
- `AudioSyncAnchorsStore` is **not** affected — bundled Play Along tracks are
  asset paths, not container paths. Only `TeacherRecordingStore` stores files.
- `record_teacher_demo_screen.dart:103-104` is the other write site; both it
  and `realign` must agree on the representation.

---

## 2. Highlight preferences are unreachable for teacher-demo-only pieces

**Component:** `PieceDetailScreen` settings panel
**Files:** `lib/screens/piece_detail_screen.dart`,
`lib/services/playback_service_base.dart`
**Severity:** two working settings cannot be reached, and would not apply if
they could
**Affects:** any piece whose only audio is a recorded teacher demo

### What happens now

Two halves, both small, and fixing either alone achieves nothing.

**The gate.** `piece_detail_screen.dart:330` hides both settings behind a
*bundled asset folder*:

```dart
if (audioSyncFolder != null) ...[
  SwitchListTile(title: const Text('Highlight downbeats only'), …),
  … Slider(…)  // 'Highlight lead'
]
```

A teacher demo is user-generated and deliberately **not** in that asset map —
see the comment at `:157-163`, which is why it is tracked by
`hasTeacherRecordingProvider` instead. So for a piece like the Galopede demo,
`audioSyncFolder` is null and neither setting renders.

**The wiring.** Even with the gate opened, `:337-338` and `:355-356` only ever
push the value into the Play Along service:

```dart
setState(() => _highlightDownbeatOnly = v);
audioSyncService?.highlightDownbeatOnly = v;   // never teacherRecordingService
```

Both services extend `PlaybackServiceBase`, which owns
`highlightDownbeatOnly` (`playback_service_base.dart:31-36`) and
`highlightLeadSeconds` (`:48`), so the capability is already there on the
teacher-demo path — only the UI never addresses it.

### Suggested approach

Widen the gate to `audioSyncFolder != null || hasTeacherRecording` (both are
already in scope at `:157-163`), and apply each change to whichever service is
active rather than to `audioSyncService` alone. Keep the two local `setState`
fields (`:97`, `:103`) as they are — they exist because the panel outlives the
autoDispose-scoped services.

### A stale test to clear up at the same time

`test/playback_service_base_test.dart:71-73` is the one failing test in the
repo and it has been failing since before this work:

```dart
test('highlightDownbeatOnly defaults to off', () {
  expect(service.highlightDownbeatOnly, isFalse);
});
```

The base class deliberately defaults it **on** (`:20`) and documents why at
`:22-30`: *"Defaults on for the same reason: it's the only highlight
granularity that's actually trustworthy."* So the default was intentionally
flipped and the test was never updated — it should expect `isTrue`. It is a
stale assertion, not a bug, but confirm that reading before changing it, since
it is the only thing currently asserting this default either way.

---

## 3. Ask the user when the tune starts, instead of inferring it

**Component:** `AudioScoreAutoAligner` / `DtwAligner`
**Files:** `lib/services/audio_score_auto_aligner.dart`,
`lib/services/dtw_align.dart`, both anchor stores, the capture screen
**Severity:** removes the one hand-tuned constant on the alignment critical
path
**Affects:** every recording with a lead-in or trail-out

### Why this is worth doing

`DtwAligner.skipPenaltyPerFrame` is currently `0.18`, and it is doing a job it
cannot do reliably: deciding, from audio alone, where the performance begins.
Two real recordings pull it in opposite directions and each pins one edge of
its usable window:

- **Galopede** has a 3s lead-in of hum that must be skipped. Below ~0.13 the
  alignment collapses (mean anchor error 18.7s).
- **Lightly Row** opens by *restating the tune's first phrase* before the
  performance proper. Above ~0.23 that intro stops being worth skipping —
  because it genuinely resembles the score — and anchor 0 is dragged from
  6.57s back to 3.09s.

The window `[0.13, 0.23]` therefore rests on **two recordings, one per edge**.
A third that is both quiet *and* opens by quoting the tune could empty it.
`test/synthetic_alignment_robustness_test.dart` widens the evidence for the
lower edge but cannot reach the upper one (its audio is rendered from the same
`MidiGenerator` that builds the reference, so it matches far too cleanly).

A user-supplied start timecode dissolves the ambiguity rather than tuning
around it. For a teacher demo the user has just watched themselves record it,
so they know the answer.

**It also fixes the tempo estimate.** `audio_score_auto_aligner.dart:106-107`
derives `estimatedBpm` from the **whole** recording's duration:

```dart
final estimatedBpm =
    (60 * quarterBeatCount / realDurationSeconds).round().clamp(20, 400);
```

On Galopede that gave 143 against a true ~168, because 8 of the 54 seconds are
not the tune. A known start (and end) makes the music span available directly,
which is the non-circular version of a two-pass tempo refinement that was
tried and dropped — iterating on DTW's own discovered span diverges, because
every reference shorter than the music is a fixed point.

### Suggested approach

Make it optional and additive, so absent input changes nothing:

1. `AudioScoreAutoAligner.align` gains `double? contentStartSeconds` and
   `double? contentEndSeconds`. Slice `realChroma.frames` to that window,
   compute `estimatedBpm` from the trimmed span, run DTW as now, then **add
   the window's start back onto every anchor's `audioSec`** so anchors stay in
   real audio time.
2. Keep `openBegin`/`openEnd` on. The timecode is a hint, not a hard edge —
   the boundaries still absorb a second or two of error, and the end still has
   to discard things like Galopede's loop-back.
3. Persist the value in both stores (nullable, defaulting to null) so
   `realign` reuses it rather than reverting to inference.
4. UI: on the capture-review step, a "tune starts here" scrub-and-mark is the
   natural place. A plain seconds field is enough to prove the idea.

### Traps

- A previous session **rejected** a manual "intro seconds" field — see
  [audio-sync-dtw-open-boundaries.md](audio-sync-dtw-open-boundaries.md),
  "Rejected alternative" — as needing per-recording tuning and not
  generalising. That judgement predates knowing the automatic decision is
  genuinely ambiguous. Read it before re-litigating, and keep inference as the
  default so the objection still holds for recordings nobody annotates.
- Do not let this become a *required* field. Bundled Play Along tracks have no
  one to ask.
- Verify against all three real recordings and the synthetic suite. Galopede
  (3s/49s) and Lightly Row (~6.5s) both have known answers; Salt Creek's
  lead-in is ~3.46s and its 32/32 onset agreement is the regression guard.

*Verified against `e6591ed`, 2026-09-15.*

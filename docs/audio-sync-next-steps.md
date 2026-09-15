# Audio-sync / teacher-demo: next steps

Written as a handoff. **Two of the three items this document originally listed
are done** — both fell out of the media-model unification rather than being
patched individually; see [piece-media-model.md](piece-media-model.md) for what
replaced them. Item 3 is unchanged and still the most valuable thing here.

**Background you will want first:**
[piece-media-model.md](piece-media-model.md) (how media are modelled now),
[audio-sync-dtw-interior-gaps.md](audio-sync-dtw-interior-gaps.md) (the most
recent alignment work, and where item 3 came from),
[audio-sync-dtw-open-boundaries.md](audio-sync-dtw-open-boundaries.md) and
[audio-sync-dtw-anchor-compression.md](audio-sync-dtw-anchor-compression.md).

---

## ~~1. A teacher recording stores absolute file paths, which do not survive~~ — DONE

Fixed by construction rather than by patch. `MediaRef`
(`lib/models/piece_media.dart`) stores either an asset key or a
**documents-relative** path, and `resolveMediaPath` recomputes the absolute
path against the current documents directory on every read — the same policy
`PieceStorage` had already adopted for MusicXML and documents at
`piece_storage_io.dart:32-34`.

There is no longer a code path that can persist an absolute path: the capture
itself now returns relative paths (`TeacherRecordingCaptureResult`), so the
representation is right at the point of creation.

Existing recordings are migrated in place on first read — `MediaMigration`
finds the `teacher_recordings/` segment in the stored absolute path and keeps
everything from there, which works on both iOS (`.../Documents/`) and Android
(`.../app_flutter/`). Covered by `test/media_migration_test.dart`, including the
real container-relocation shape from the original bug report.

## ~~2. Highlight preferences are unreachable for teacher-demo-only pieces~~ — DONE

Both halves are gone. The gate in `piece_detail_screen.dart` was
`audioSyncFolder != null` — the presence of a *bundled asset folder* — and now
reads `!selectedMedia.isSynthesized`, which is what the settings actually
describe. The wiring underneath pushed only into the Play Along service; there
is now one `MediaPlaybackService` to push into, so opening the gate is
sufficient rather than half a fix.

The stale assertion at `test/playback_service_base_test.dart:71` is corrected:
the base class defaults `highlightDownbeatOnly` **on** and documents why at
`:22-30`. That was the repo's one failing test; the suite is now green.

One thing worth knowing: the two settings still live as local `setState` fields
on the screen, because the panel outlives the autoDispose-scoped service. They
are re-applied to the service on every build (both setters early-return when
unchanged), which is what makes them survive a service being torn down and
recreated. Before, they silently did not.

---

## 3. Ask the user when the tune starts, instead of inferring it

**Component:** `AudioScoreAutoAligner` / `DtwAligner`
**Files:** `lib/services/audio_score_auto_aligner.dart`,
`lib/services/dtw_align.dart`, `lib/models/piece_media.dart`,
`lib/screens/record_teacher_demo_screen.dart`
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

**This matters more than it did.** Imported media are now first-class (any
mp3/m4a/mp4 the user picks is decoded and aligned), so the aligner no longer
only sees audio this project produced. A lesson recording with two minutes of
talking before the tune is an ordinary thing to import, and it is exactly the
case a single global penalty constant handles worst.

**It also fixes the tempo estimate.** `audio_score_auto_aligner.dart` derives
`estimatedBpm` from the **whole** recording's duration:

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

1. `AudioScoreAutoAligner.alignChroma` gains `double? contentStartSeconds` and
   `double? contentEndSeconds`. Slice `realChroma.frames` to that window,
   compute `estimatedBpm` from the trimmed span, run DTW as now, then **add
   the window's start back onto every anchor's `audioSec`** so anchors stay in
   real audio time. `alignChroma` is the right seam — `align` (WAV bytes) and
   `alignPcm` (decoded media) both funnel through it, so both entry points get
   the feature for free.
2. Keep `openBegin`/`openEnd` on. The timecode is a hint, not a hard edge —
   the boundaries still absorb a second or two of error, and the end still has
   to discard things like Galopede's loop-back.
3. Persist the value on `PieceMedia` (nullable, defaulting to null) rather than
   on `MediaAlignment`: it is a fact about the recording, not about one
   alignment run, so it must survive `realign` clearing the alignment row.
   `PieceMedia.fromJson` already tolerates absent fields, so this needs no
   schema version — add it as nullable and old entries read as null.
4. UI: on the capture-review step, a "tune starts here" scrub-and-mark is the
   natural place. A plain seconds field is enough to prove the idea. The media
   picker's per-medium row is the obvious home for editing it afterwards.

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

---

## 4. The native decoder has not been exercised on real compressed audio

**Component:** `AudioDecoder`
**Files:** `ios/Runner/AudioDecoderPlugin.swift`,
`android/app/src/main/kotlin/com/example/violin_practice_companion/AudioDecoderPlugin.kt`
**Severity:** a new feature whose happy path is unconfirmed on device
**Affects:** importing anything that is not a WAV

The Dart side's contract is pinned by `test/audio_decoder_test.dart` (Float32 →
Float64 widening, every malformed-reply shape, failure-is-null rather than
throw, and that WAV never reaches the channel). The iOS plugin compiles and is
registered. What has **not** happened is a real mp3/m4a/mp4 going in one end
and chroma coming out the other, on a device or simulator.

Things most likely to be wrong, in order:

- **Android `MediaFormat.KEY_PCM_ENCODING`.** The plugin assumes 16-bit unless
  the output format says float, and reads that only from
  `INFO_OUTPUT_FORMAT_CHANGED`. Devices vary; a wrong guess here yields
  plausible-looking noise rather than an error.
- **iOS sample rate.** It is read from the track's format description and then
  handed back to `AVAssetReaderTrackOutput` as the output rate. For a file
  whose container and track disagree, the returned `sampleRate` could describe
  the source rather than the output, which would stretch every anchor.
- **A video with no audio track** returns an error on both platforms, which the
  Dart side turns into `playsWithoutHighlight`. That path is reachable and
  untested end to end.

Cheapest check: import a known-duration mp3 of a bundled tune and confirm
`PcmAudio.durationSeconds` matches the file, then that its anchors land where
the WAV's do.

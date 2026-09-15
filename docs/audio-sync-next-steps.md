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

## 4. The native decoder — iOS confirmed, Android still unverified

**Component:** `AudioDecoder`
**Files:** `ios/Runner/AudioDecoderPlugin.swift`,
`android/app/src/main/kotlin/com/example/violin_practice_companion/AudioDecoderPlugin.kt`

The Dart side's contract is pinned by `test/audio_decoder_test.dart` (Float32 →
Float64 widening, every malformed-reply shape, failure-is-null rather than
throw, and that WAV never reaches the channel).

**iOS is confirmed end to end.** A 320 kbps 44.1 kHz joint-stereo mp3 (~71.4s,
a violin+piano performance of The Happy Farmer) decoded through AVAssetReader,
extracted chroma and produced 42 anchors spanning **6.87s → 66.57s**, at
`generationBpm` 136. That span is the check that matters: a wrong sample rate —
the risk this section originally called out — scales every anchor, so anchors
landing inside a 71.4s file with a plausible lead-in and trail-out is direct
evidence the rate came back right. The stereo mixdown path is exercised too.

Two things that fell out of the run:

- The alignment is flagged `hasCompressedAnchors`. Given the known
  false-positive mode (see `alignmentReviewMessage`), this is not necessarily a
  decoder or score problem, but it has not been looked into.
- It skipped a **6.9s intro**, which this recording genuinely has. That is item
  3's case arriving on its own, from real imported audio rather than from a
  recording made by this project.

**Android is untested.** The thing most likely to be wrong is
`MediaFormat.KEY_PCM_ENCODING`: the plugin assumes 16-bit unless the output
format says float, and reads that only from `INFO_OUTPUT_FORMAT_CHANGED`.
Devices vary, and a wrong guess yields plausible-looking noise rather than an
error — so check the anchor span the same way, don't just look for a crash.

**Also still untested:** a video with no audio track. Both plugins return an
error and the Dart side turns it into `playsWithoutHighlight`; that path is
reachable and has not been walked.

### Getting a file onto the simulator to test with

`scripts/sim_add_media.sh dev-iphone <pieceId> <file> ["Label"]` attaches a
file to a piece from the CLI and runs the app's real load path. It exists
because the in-app route goes through the **system document picker**, which is
native iOS: Marionette only sees Flutter widgets, so an agent cannot drive it.

Two traps it encodes, both of which cost time to find:

- **`defaults write <bundle>` does not reach the app.** On the simulator that
  writes to the device's shared preferences domain, while an iOS app reads
  NSUserDefaults from its own data container's
  `Library/Preferences/<bundle>.plist`. Edit that plist directly.
  `shared_preferences` prefixes every key with `flutter.`.
- **A `flutter run` reinstall relocates the data container** — three different
  UUIDs in one session. Documents and the plist are carried across, so writing
  before a relaunch works, but never cache the container path across a launch.
  (This is also the failure mode item 1 fixed, seen live: the legacy
  `teacherRecording.galopede` key still names a container from two moves ago.)

The app must be stopped while the plist is edited — a running app holds
NSUserDefaults in memory and flushes over anything written underneath it.

For the Files app instead, copy into the simulator's "On My iPhone" storage:
`.../data/Containers/Shared/AppGroup/<group.com.apple.FileProvider.LocalStorage>/File Provider Storage/`
(find the group by its `MCMMetadataIdentifier` in each container's
`.com.apple.mobile_container_manager.metadata.plist`), then pick it in the app
via Browse ▸ On My iPhone.

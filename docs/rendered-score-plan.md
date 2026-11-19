# Plan: play the synthesized score as a rendered recording

Status: starting plan, 2026-11-18. Nothing built yet.

## Why

Every recording on iOS now plays through one native AVPlayer
(`ios/Runner/VideoTransportPlugin.swift`, `lib/services/media_transport.dart`).
AVPlayer's position already allows for the speaker's delay. Calibrating
through that player measured **14 ms on the iPad speaker and 8 ms on a Sonos
over AirPlay**, so recordings need no calibration.

The synthesized score is the exception. `PlaybackService`
(`playback_service_io.dart`) strikes notes live through flutter_midi_pro's 16
AVAudioEngines, on the app's own clock. Nothing on that path allows for the
speaker, so it must be calibrated. The measured delay is also unstable: on the
same Sonos it was 2046, 907, 916, 2041, 2048 and 584 ms. It changes each time
the engines are rebuilt for a speaker change, so a stored calibration goes
stale (seen 2026-11-18: Simulated out of sync until recalibrated). The live
synth has other speaker problems too. Its engines don't follow a route change
(rebuilt by hand, `bca67c8`). Built while a recording held an AirPlay
speaker, they stayed silent (`cd8aebd`).

The idea: render the score to an audio file, then play it like any other
recording, through the same native player. The score then gets AVPlayer's
compensation, follows route changes, shares one transport with recordings,
and needs no calibration.

## What stays the same

- `MidiGenerator` → `MidiData` / `scheduledNotes` stays the source of truth
  for what sounds, and when.
- The highlight doesn't need DTW for a rendered score. The file is made from
  the note schedule, so score time maps to audio time exactly (a linear map at
  the rendered tempo, or anchors written at render time). That lets the score
  load through `MediaPlaybackService` with a known alignment, so it gets clip
  end, seek and count-in for free.

## Open questions, to answer first (spike)

1. **Renderer.** It has to render offline, faster than real time, ideally on
   both iOS and Android.
   - A pure-Dart SF2 synth (e.g. `dart_melty_soundfont`, a MeltySynth port):
     one code path for both platforms, in an isolate. Check its quality and
     speed against flutter_midi_pro's sound with our bundled 0.9 MB soundfont
     (`3c93130`).
   - iOS native: `AVAudioEngine` manual rendering mode with
     `AVAudioUnitSampler` loading the SF2. Fast, but iOS-only, so Android
     would need its own renderer.
   - Measure render time for a 2-minute piece on the slowest target
     (`dev-android-low`, an older iPad). The target is under 1 s, or progressive.
2. **Tempo changes.** Re-render at the new tempo (exact, costs a render), or
   time-stretch with the player's rate (`.timeDomain`, smears at 0.5×)?
   Probably re-render, cached per (piece content hash, tempo, instrument,
   velocity, mute state), and use stretch only for a moment while the new
   render is made. A tempo change mid-play needs a seamless swap at the
   same score position.
3. **Count-in and claves.** Today the count-in is struck live. Options:
   render it into the file as a pre-roll (simplest, and then it's in sync by
   construction), or strike it live and accept the uncompensated delay. That
   delay is real on AirPlay, so render it.
4. **What the live synth does that a file can't.** Inventory
   `PlaybackService` before deciding: mute (`onMuteChanged`), instrument and
   velocity (`assets/engine/…` json), setEnd / selection, loops, tempo
   slider, `strikeAheadSeconds`, highlight lead. Each needs an equivalent:
   most map to seek, clip-end and re-render.
5. **Android.** ExoPlayer's position should also allow for output latency.
   Verify with the calibration (Android has no calibration plugin yet; see
   CLAUDE.md "What's native on Android").

## Phases

1. **Spike (no app changes):** render one piece (e.g. Lightly Row) offline
   with the candidate renderer(s) to a WAV. Compare by ear with the live
   synth, and time it on dev-iphone-se, dev-android-low and Hazel iPad.
2. **Rendered score as a medium:** a generated `PieceMedia` (synthesized,
   file in the cache dir) with exact anchors, played by `MediaPlaybackService`
   through `NativeTransport`. Selection, loop and count-in come from the
   recording path. Keep the live synth behind a switch for comparison.
3. **Tempo:** cache and re-render, plus the mid-play swap.
4. **Retire calibration for the score:** confirm about 0 ms on the iPad
   speaker, Kitchen, the Roam and a Bluetooth speaker, with the playback
   trace (`pull_sync_trace.sh`). Then drop the score calibration. Keep a
   small manual sync nudge as a safety valve, and keep the calibration tool
   as a diagnostic only.
5. **Remove** the synth's speaker-following machinery once nothing plays
   live (rebuild on route change, deferral, engine-reset checks), if the
   claves no longer need it.

## Risks

- The render quality or speed of a pure-Dart synth may not match.
- Memory/disk: 2 min of 44.1 kHz mono 16-bit is ~10 MB per tempo. Cache
  few, and evict.
- Latency to first sound after a change (tempo, mute, edit) if a render has
  to finish first. That points to progressive rendering: start playing the
  first seconds.

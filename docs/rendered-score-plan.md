# Plan: play the synthesized score as a rendered recording

Status: phases 1–3 built on branch `rendered-score` (2026-11-19), checked on
`dev-iphone-se` and `dev-android-low`; not yet heard by ear or timed on a
physical device. See "Progress" at the end.

## Why

Every recording on iOS now plays through one native AVPlayer
(`ios/Runner/VideoTransportPlugin.swift`, `NativeTransport` in
`lib/services/media_transport.dart`). AVPlayer's position already allows for
the speaker's delay. Calibrating through that player measured **14 ms on the
iPad speaker and 8 ms on a Sonos over AirPlay**, so recordings need no
calibration.

The synthesized score is the exception. `PlaybackService`
(`playback_service_io.dart`) strikes notes live through flutter_midi_pro's 16
AVAudioEngines, on the app's own clock, and allows for the speaker only by a
calibrated delay (`AudioOutput.heardDelaySeconds(AudioSyncSource.score)`).
That delay is unstable: on the same Sonos it was 2046, 907, 916, 2041, 2048
and 584 ms. It changes each time the engines are rebuilt for a speaker
change, so a stored calibration goes stale (seen 2026-11-18). The engines also
don't follow a route change (rebuilt by hand, `bca67c8`), and engines built
while a recording held an AirPlay speaker stayed silent (`cd8aebd`).

The idea: render the score to an audio file, then play it like any other
recording, through the same native player. It then gets AVPlayer's
compensation, follows route changes, shares one transport with recordings,
and needs no calibration.

**The bar is "as good as a recording", not "as good as the live synth".**
Wherever the recording path behaves differently (a tempo change restarts the
bar, a loop seam, a mid-piece count-in), the rendered score takes the
recording's behaviour.

## What stays the same

- `MidiGenerator` → `MidiData` stays the source of truth for what sounds, and
  when.
- No DTW. The file is made from the note schedule, so the anchors
  (`ScoreAudioAnchor`, score ms ↔ audio s) are written at render time and are
  exact. The score loads through `MediaPlaybackService` with that alignment,
  so selection, clip end, seek, loop and count-in come from the recording
  path. (This reverses the note at `media_playback_service.dart:92`, which
  says the synthesized score deliberately isn't there. Update it when built.)
- The highlight lead (`highlightAdvanceSeconds`) and the count-in display
  already work on a recording's clock.
- The instrument stays the violin patch from `midi_patch.json`. It isn't a
  setting, and the synth is a guide to the notes, not to phrasing, so the
  choice of sound is deferred.

## Decisions

### Count-in: a woodblock intro in the file

Today the count-in makes no sound: the numbers and dot are shown, and the
first note is struck when the count ends. The claves are used only for
calibration. A heard count is wanted, so the file starts with **three bars of
woodblock** at the render's tempo: one click per counted beat, as
`barCounting` (`lib/models/count_in.dart`) counts them. That is quarters in
2/4, 3/4 and 4/4 and dotted quarters in 6/8. The first beat of each bar takes
the high block (GM key 76) and the others the low one (77). A pickup shortens
the last bar, as `CountInPlan` already does.

The pre-roll is then just a recording's intro. A start from the top plays the
file from 0, and `recordingLeadIn(fromBeginning: true)` lays the visual count
over the intro's last beats. When the count is longer than the intro (count
setting over three bars), it already tops the gap up with silence. The anchors
start after the pre-roll.

- The woodblocks have to go into the soundfont subset: rerun
  `scripts/subset_soundfont.py` with keys 76/77 alongside the claves.
- **A start mid-piece** gets no woodblocks: it follows the recording lead-in
  mode in force (silent wait, or preroll of the bars before). Like a
  recording. Open question 3 checks whether the silent wait lands on time.

### Mute: not part of the rendered score

To play the score without sound, people choose the silent option (cursor and
count, nothing heard). That needs no render and has nothing to sync, so it
stays a clock-only player (`PlaybackServiceBase` with no audio). No volume
control is added to `MediaTransport`.

*Revised 2026-11-19:* Silent migrates off the live synth (phase 5) — to
its own clock-only player, as above, not a muted rendered file. A muted
AVPlayer played aloud on Kitchen (its volume is ignored on AirPlay), and
holding the speaker for nothing helps no one: Silent needs only the cursor
at the tempo.

### Tempo: three renders, nearest plus stretch

What matters is **60–120% of the performance tempo** (P, the piece's
`TempoPreset.performance`). Render three files at about **0.67 P, 0.85 P and
1.07 P**. Each covers a band of a factor of 1.26, so playing the nearest one
at a rate of r ≤ 1.12 or ≥ 0.89 keeps the stretch within ±12%
(`setSpeed`, which `MediaPlaybackService.setPlaybackSpeed` already does, with
the anchors scaled by `playbackSpeed`). Outside 60–120% (Slow can go down to
20%) the nearest render is just stretched further. It smears, and that's
accepted.

- The BPM slider stays for the score: a BPM maps to (render, rate). The
  recordings' speed control isn't shown for it.
- Within a band, a tempo change is just a rate change mid-play. Crossing into
  another band switches the file and restarts at the bar being played, as
  `setTempo` does today. No seamless mid-play swap.
- Render the one nearest the current tempo first, and the other two in the
  background.
- **Cache key:** a hash of the note schedule (`MidiData.notes`, so a fingering
  or lyric edit doesn't re-render) plus render BPM, meter and pickup (for the
  woodblock bars) and the soundfont/`midi_patch.json` version. Keep a few
  pieces, evict the least recently used. Files go in the cache directory:
  `NativeTransport` only opens files, while bundled assets fall back to
  just_audio.

### Android: same files, function-checked on the emulator only

On Android every recording plays through `JustAudioTransport` (ExoPlayer
underneath), with the recording delay at 0 and no calibration plugin. There
is no physical Android device to measure latency on, so the bar there is that
it **works on `dev-android`**. It plays, the highlight follows, a tempo change
picks the right render, and the woodblocks land on the count. Latency on real
Android speakers is a known unknown. This favours a renderer that runs on
both platforms (open question 1).

## Open questions (spike)

1. **Renderer.** Offline, faster than real time, preferably on both
   platforms.
   - A pure-Dart SF2 synth (e.g. `dart_melty_soundfont`, a MeltySynth port):
     one code path, in an isolate. **Preferred**, since Android would get it
     for free.
   - iOS native: `AVAudioEngine` manual rendering with `AVAudioUnitSampler`.
     It would sound like today's synth, but Android would keep the live synth.
   - Target: all three renders of a 2-minute piece in a few seconds on the
     slowest targets (`dev-iphone-se`, an older iPad, `dev-android-low`), with
     the first one under ~1 s. If not, render the first from the start bar.
     Progressive playback of a half-written file doesn't fit AVPlayer.
2. **Format: the same as the app's own recordings.** An in-app teacher
   recording's sound is AAC, mono, 44.1 kHz, about 64 kbps, in an `.mp4`
   (`afinfo` on Galopede's demo). Render to exactly that, with the platform's
   own AAC encoder: `AVAssetWriter` on iOS, MediaCodec + MediaMuxer on
   Android (a new native piece there, behind a façade). The file then goes
   down the same decode and playback path as a recording. About 0.48 MB per
   minute. The three renders add up to about 3.6× the piece's length at
   performance tempo, plus the woodblock bars, so all three come to about
   **1 MB for a 30 s piece, 2 MB for 1 minute, 4 MB for 2 minutes**.
   - **Encoder priming.** AAC starts with about 2112 samples of priming
     (~48 ms at 44.1 kHz). AVAssetWriter records it so AVPlayer skips it;
     MediaMuxer may not, which would put every anchor ~48 ms early on
     Android. Check: decode the rendered file
     (`AudioDecoderPlugin` / `AudioDecoder`) and find the first woodblock's
     onset against where it was rendered.
3. **Mid-piece silent count-in.** The silent lead-in waits on the phone's
   clock and then calls `play()`. If AVPlayer starts late after a pause on
   AirPlay, the first note lands after the count. This affects recordings
   too. Measure it on Kitchen with the playback trace. If it's late, fix it
   for both: count against AVPlayer's own timebase, or start the player
   paused on a silent pre-roll.
4. **Loop seam.** A recording loops by waiting out the clip end, seeking and
   playing again. Measure the gap on a short looped selection over AirPlay.
   Accept whatever recordings do, but write it down.

## Phases

1. **Spike (no app changes):** render Lightly Row with the woodblock intro
   at one tempo, encoded as above, with the candidate renderer(s). Compare by ear with
   the live synth, and time three renders on dev-iphone-se,
   dev-android-low and Hazel iPad.
2. **Rendered score as a medium:** a generated medium (synthesized, file in
   the cache dir) with exact anchors and the woodblock pre-roll, played by
   `MediaPlaybackService`, through `NativeTransport` on iOS and
   `JustAudioTransport` on Android. Silent stays a clock-only player. Keep
   the live synth behind a switch for comparison.
3. **Tempo:** three renders, BPM → (render, rate), background rendering,
   cache and eviction.
4. **Retire calibration for the score:** confirm about 0 ms on the iPad
   speaker, Kitchen, the Roam and a Bluetooth speaker with the playback trace
   (`pull_sync_trace.sh`). Answer open questions 3 and 4 there. Then drop the
   score calibration, keep a small manual sync nudge as a safety valve, and
   keep the calibration tool as a diagnostic only. Android: the emulator
   check above.
5. **Silent off the live synth:** `SilentPlaybackService`, the base class's
   clock with no audio, so it holds no speaker. Done (below).
6. **Remove the live synth** once nothing plays through it: its
   speaker-following (rebuild on route change, deferral, engine-reset
   checks). The calibration tool's score check is the last thing that plays
   claves through it, and goes with the score calibration.

## Risks

- A pure-Dart synth's quality or speed may fall short (open question 1).
- First sound after opening a piece or changing tempo band waits on a
  render, unless the cache already has it.
- Three renders per piece triple the render time (plus an AAC encode each).
  Disk is small, ~2 MB per one-minute piece for all three. Render lazily,
  nearest first; the other two may never be needed.
- Android latency is unmeasured, and will stay so until there is a physical
  device.

## Progress (2026-11-19)

**Built:**
- `lib/services/score_renderer.dart`: `MidiData` → mono PCM with the
  pure-Dart MeltySynth port (`dart_melty_soundfont`, MIT), violin on channel 0
  dry, woodblocks (76 high on each bar's first beat, 77 low) on channel 9,
  three bars as `countInPlan` counts them, less the pickup. Events land on
  32-sample blocks (0.7 ms). Exact anchors, one per performed measure.
- `rendered_score_cache_io.dart`: render in an isolate, write a WAV, encode
  with `encodeAac` on the decoder channel (AVAudioFile on iOS,
  `AacEncoder.kt` MediaCodec + MediaMuxer on Android), WAV kept where there is
  no encoder. Key = notes + measure onsets + bpm + meter/pickup + patch +
  soundfont size + renderer version. LRU, 12 files.
- `RenderedScorePlaybackService extends MediaPlaybackService`, through
  `MediaPlaybackService.loadAligned`: three renders at 0.67/0.85/1.07 P,
  nearest by ratio, rate for the rest; a band change mid-play reloads and
  resumes at the bar (`PlaybackServiceBase.resumePoint/resumeAt`). The other
  two render in the background, one at a time.
- The synthesized tray plays whatever is active, and shows a spinner until
  the first render is in. Settings has a "Rendered score" switch (default
  on, not remembered) back to the live synth. Silent still uses the live
  synth, muted.
- Soundfont re-cut with `--keep 128:0:75,76,77` (README updated).

**Open question 1 (renderer): pure Dart is fast enough.** Lightly Row
(47–75 s with the count): host 400× real time; `dev-iphone-se` (debug, JIT)
75 s in 223 ms + 170 ms encode; `dev-android-low` (debug) 55 s in 0.7 s,
encode 1–1.5 s, but **6.4 s for the first encode after launch** (codec cold
start?). Release on a phone and on Hazel iPad still to time.

**Open question 2 (priming): fine on both.** iOS: AVAudioFile writes the
2112 priming frames and a decode puts the first click on its rendered
sample (offset 0). Android: MPEG4Writer also records 2112, and Apple's
decoder puts the audio 64 samples (1.5 ms) early. Whether ExoPlayer honours
that edit list is not measured.

**Count-in off skips the woodblocks** (decided 2026-11-19): a from-the-top
start with no count seeks to the first bar
(`MediaPlaybackService.playsIntroWithoutCount`, false for the rendered
score). A recording's own intro still plays from 0.

**Phase 5 (Silent), built:** Silent is `SilentPlaybackService`, the base
class's clock with no audio, whichever way the rendered-score switch is
set; the live synth is no longer muted for it. Tried first and dropped:
the rendered file at volume 0 (`MediaTransport.setVolume`), which played
aloud on Kitchen because AVPlayer's volume is ignored on AirPlay. Leaving
Silent mid-play for another track stops, as any track change does.

**Loop on AirPlay (open question 4), fixed, to re-test on Kitchen:** one
clip end restarted the loop twice in 16 ms. A native event sent before the
seek back to the loop start arrived after it, still saying "completed at
the end", and the completion watcher took it for a second end. The
overlapping seeks, plays and pauses then wedged AVPlayer: timeControlStatus
playing, the item's clock at rate 0, through the next Play from the same
spot too, until a seek elsewhere. `NativeTransport` now ignores events while
a seek is in flight; and the native player re-seeks 50 ms back if its clock
stands still for 1.5 s of "playing" (traced as "stalled while playing").

**Open question 3 (mid-piece count-in):** the silent wait, then the player
running within 10–25 ms of the call, on Kitchen and on the ZVOX. Heard
timing not yet measured.

**Calibration (Jamz, 2026-11-19):** recording path 8 ms on Kitchen, 92 ms on
the ZVOX (which reports 83 ms output latency: AVPlayer doesn't allow for
Bluetooth's); live synth 2040 ms and 213 ms. The rendered score is on the
recording path, so the score calibration no longer applies to it.
Release render timing on Jamz: 275 s of audio rendered in 0.56 s, encoded
in 0.53 s; one-minute pieces ~0.1 s each.

**Device timing:** each render appends its timing line to
`Documents/rendered_score_log.txt`; play-throughs trace as
`=== playback rendered score`.

**Found on the way:** the first Play after a launch counted in with the
count-in off: the saved count was read back only once Play first asked,
so Play got the default. The tray now watches it (and the lead-in mode).

**Not done:** listening comparison with the live synth; device timing; phase
4 (calibration retirement, open questions 3–4); phase 6.


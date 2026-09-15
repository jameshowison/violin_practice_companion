# DTW auto-alignment: a quiet, hum-dominated recording aligned to the wrong part of itself

**See also:** [audio-sync-dtw-open-boundaries.md](audio-sync-dtw-open-boundaries.md)
(the open-begin/open-end mechanism whose skip penalty this re-tunes) and
[audio-sync-dtw-anchor-compression.md](audio-sync-dtw-anchor-compression.md)
(the `hasCompressedAnchors` signal, which this gives a known false-positive mode).

**Component:** `AudioChromaExtractor` / `DtwAligner` / `AudioSyncPlaybackService`
**Files:** `lib/services/audio_chroma_features.dart`, `lib/services/dtw_align.dart`,
`lib/services/audio_sync_playback_service.dart`
**Severity:** alignment wrong by tens of seconds — the feature is unusable on an
affected recording, though nothing crashes
**Affects:** any recording that is quiet relative to its own noise floor.
Confirmed case: the Galopede teacher demo (`docs/photos_no_share/galopede_video.MOV`,
gitignored, author-supplied), a mandolin play-through recorded at low level with a
background hum.

## Summary

`AudioChromaExtractor` folded **raw FFT magnitudes from 80 Hz up** into its 12
pitch classes. On the Galopede demo, 81% of the recording's energy sits below
200 Hz — a hum whose loudest bins are 54-205 Hz — so every frame's chroma was
mostly a re-binning of that hum, and therefore nearly identical to every other
frame's. No melody fundamental lives below 196 Hz (G3, the lowest note on both
violin and mandolin), so none of that band carried signal; it was all noise,
and it outvoted the notes.

With the cost matrix that flat, `DtwAligner`'s open boundaries did the rest.
`_skipPenaltyPerFrame` was `1e-3`, three orders of magnitude below the cost of
matching anything, so declining a target frame was effectively free — which
let the path pick whichever short window of audio happened to match best and
stack the whole reference into it with vertical moves. The result put the first
anchor at 22.0s when the first note is at 3s, and declared the tune finished at
40.6s. The user's report was that on-phone playback looked "almost like only
the second half was happening": the highlight raced through the whole score
during the middle of the recording and had nothing left to do for the rest.

## Ground truth

Author's, by ear. There is **no spoken narration anywhere in this recording** —
see "What the first diagnosis got wrong" below.

| event | audio |
|---|---|
| first note (pickup) | 3s |
| A part repeats | 15s |
| B part begins | 25s |
| C part begins | 37s |
| tune ends, loops back to the top | 49s |
| video cuts off | 54s |

33 performance measures (a pickup plus 24 written measures, repeat over 1-8)
across 3-49s is ~1.4s per measure, i.e. ~168 quarter-BPM.

## Fixes

### 1. Band-limit and de-hum the chroma front end (the big one)

`AudioChromaExtractor` gained `noiseSubtractionFactor` / `noisePercentile`, and
its default band moved from 80-5000 Hz to **180-2600 Hz** — just under G3, so
no real fundamental is excluded, and above E7, beyond which partials are mostly
bow/pick noise and room tone.

The noise profile is each bin's 10th-percentile magnitude over the whole
recording, taken from up to 400 evenly-spaced frames (a second STFT pass, so a
long recording's spectra don't all have to be held in memory), and `1.5x` it is
subtracted per frame before folding. A constant hum sits at nearly the same
level in every frame, so a low percentile estimates it well; a played note is
present in a minority of frames and survives.

Measured on the demo's melody band, dynamic range is 19.7 dB raw and 23.8 dB
after subtraction, against **1.6 dB** for the full-band RMS the old extractor
effectively saw. Band-limiting is most of the win; subtraction adds ~4 dB.

Two things this does *not* do, both worth knowing:

- It does not silence non-music frames. All 2326 frames of the demo still have
  something above the floor afterwards, because the hum's own frame-to-frame
  variance exceeds the margin. What it removes is their *resemblance to the
  score*, which is what the alignment actually depends on.
- It removes a perfectly stationary tone outright, because such a tone *is* the
  recording's stationary spectrum. That is correct for alignment — a component
  present identically in every frame says nothing about where in the recording
  you are — but it means `audio_chroma_features_test.dart`'s pure-tone mapping
  tests now pass `noiseSubtractionFactor: 0` explicitly, and a drone held under
  a whole performance would be suppressed.

### 2. Re-tune the open-boundary skip penalty

`DtwAligner._skipPenaltyPerFrame` (a private constant) became
`skipPenaltyPerFrame` (a constructor field), default **0.18**, up from `1e-3`.

The original value was chosen only to break the near-ties a long sustained
stretch of near-identical frames produces, and that reasoning was sound as far
as it went — but it left the penalty far below the cost of matching anything.

What the penalty actually buys is **coverage**. Every reference frame pays its
own cosine distance wherever it lands, so skipping saves nothing directly; but
a near-free skip lets the path choose any sub-window and cram the reference
into it, picking the best-matching frames and ignoring whether the result is a
plausible passage of time. Charging per declined target frame is what makes a
narrow window expensive and a wide, roughly diagonal path win. Chroma vectors
here are non-negative and unit-length, so cosine distance is bounded in `[0, 1]`
(not the `[0, 2]` the general case allows) and a whole-alignment mean near 0.4
is normal — so the useful range for this is a fraction of that, well below the
cost of matching but far above the old `1e-3`.

**0.18 is the centre of a window, and the window is the interesting part.**
Each edge is pinned by a different recording, and by a different mechanism:

| penalty | 0.001 | 0.05 | 0.10 | 0.13 | **0.18** | 0.23 | 0.30 | 0.45 |
|---|---|---|---|---|---|---|---|---|
| Galopede mean anchor err | 18.7 | 18.7 | 3.97 | 0.60 | **0.60** | 0.60 | 0.60 | — |
| Lightly Row anchor 0 | 6.78 | 6.69 | 6.57 | 6.57 | **6.57** | 6.57 | 3.09 ✗ | — |
| worst synthetic anchor-0 err | 0.53 | 0.53 | 0.29 | 0.04 | **0.05** | 0.05 | 0.06 | 5.00 ✗ |

- **Too low** and Galopede's window collapses (see the Results table below).
- **Too high** and Lightly Row's first anchor is dragged back into its intro.
  That recording opens by restating the tune's first phrase before the
  performance proper, so the intro genuinely resembles the score's opening and
  stops being worth skipping once declining it gets expensive: anchor 0 jumps
  6.57s → 3.09s and the first segment then paces at 2.4x the rest of the
  piece, where a correct anchor 0 paces at 1.04x. That is the same symptom
  [audio-sync-dtw-open-boundaries.md](audio-sync-dtw-open-boundaries.md) was
  written to fix, and it was briefly re-introduced here at 0.25 before
  `test/lightly_row_intro_align_test.dart` was added to catch it.
- The synthetic row comes from `test/synthetic_alignment_robustness_test.dart`
  (13 conditions, exact ground truth). It agrees on the lower edge and puts
  the upper edge further out, at 0.45, where an unrelated intro stops being
  skipped — a different mechanism from Lightly Row's.

**A recording whose intro or outro quotes the tune is the hard case**, and
raising this value is what breaks it. Note the upper edge still rests on one
real recording: the synthetic `INTRO QUOTES TUNE` condition does *not*
reproduce Lightly Row's failure, because its notes are rendered from the same
`MidiGenerator` that builds the reference and so match it far too cleanly.

### 3. Guard the anchor interpolators against zero-width segments

Separate latent bug, found on the way. Both `AudioSyncPlaybackService` and
`TeacherRecordingPlaybackService` map score time to audio time by dividing by a
segment's delta, with no zero check — so two anchors sharing an `audioSec` made
the interpolation `±inf`/NaN and threw the cursor to the end of the piece (or
nowhere) while that segment was bracketed. `sortAnchors` already knew such ties
occur and only fixed their *ordering*. Real alignments produce them: the old
Galopede anchors had three ties and Salt Creek's had one.

`AudioSyncPlaybackService.dropDegenerateSegments` now runs after `sortAnchors`
at both call sites, keeping the last anchor of each equal-`audioSec` run (the
earliest instant the audio can be said to have reached all of them; keeping the
first would stall the cursor) and never returning fewer than 2 anchors.

## Results

Galopede demo, mean absolute anchor error against the ground-truth table:

| skip penalty | a0 (3s) | a9 (15s) | a17 (25s) | a25 (37s) | last | mean err |
|---|---|---|---|---|---|---|
| 1e-3, old front end (shipped) | 22.04 | 26.22 | 32.88 | 38.94 | 40.57 | **10.0s** |
| 1e-3, new front end | 31.86 | 36.53 | 41.03 | 45.21 | 46.02 | 18.7s |
| **0.18, new front end** | **2.95** | **14.88** | 26.38 | **37.85** | 47.79 | **0.60s** |

Note the middle row: better features **alone made it worse** — 10.0s of mean
error became 18.7s — because sharper discrimination makes the cheap parking
spot relatively cheaper still. The two fixes only work together, and in this
order they look like a regression: fix the features first and measure, and you
would conclude the change had backfired.

`hasCompressedAnchors` on this recording is now `false` (was `true`).

Salt Creek (`assets/audio/salt_creek/melody.wav`, the known-good clean
recording) improved too, on its own independent chroma-free onset cross-check:
anchor-to-nearest-onset **median 0.049s -> 0.044s, mean 0.065s -> 0.043s,
within-100ms 26/32 -> 32/32**, `averageDtwCost` 0.1974.

The reference tempo turned out not to matter. `estimatedBpm` is computed from
the *whole* recording's duration, which on a recording with a real intro or
outro underestimates it — here 143 against a true ~168. Forcing the correct
value changes the mean anchor error by 0.01s, because DTW's warping absorbs a
17% tempo error without trouble. A planned two-pass tempo refinement was
dropped on that evidence.

## What the first diagnosis got wrong

The first version of this document (and `test/galopede_teacher_demo_align_test.dart`
as originally written) diagnosed the failure as **interior narration gaps**: it
reported a ~22s spoken intro, spoken "A part"/"B part"/"C part" announcements at
each section change, and a loop-back at the end, and concluded that DTW needed a
second DP state so a run of target frames could be skipped mid-recording. It
recommended building that.

None of the narration exists. The recording is continuous playing from 3s to
49s. The "22s spoken intro" was the *old aligner's own wrong first anchor* being
read back as a fact about the audio, and the anchor compression at the "B->C
boundary" was one of 76 stall runs spread across all three sections — 65% of the
reference was consumed by zero-audio-time vertical moves, with the largest early
run in the middle of the A part. A narration gap would appear as a *horizontal*
run (audio advancing while the score waits) and would be a high-cost region; the
observed artefact was *vertical* and its stall buckets were the **cheapest** on
the path (0.452/0.454 against a global mean of 0.502), which only over-long or
under-discriminating reference material causes.

So no interior-skip state was built. DTW already routes around an interior gap —
it goes horizontal, at real cost — and `test/dtw_align_test.dart` now pins that
behaviour: the reference frames on the far side of a poisoned stretch still land
exactly right. If a recording with genuine mid-performance narration does turn
up, the two-state DP in the original write-up is still the design to reach for,
but it should be built against that recording, not this one.

Two process notes worth keeping, because both cost real time here:

- **A flat level histogram and a low-frequency-dominated spectrum are not proof
  of a dead recording.** This file reads as 54s of stationary noise by every
  bulk statistic — 1.6 dB RMS spread over its whole length, 96.5% of energy
  below 500 Hz, no usable onsets — and was confidently (and wrongly) written off
  as a failed capture, twice, before the author's by-ear timeline contradicted
  it. A hum loud enough to dominate the statistics hides a perfectly usable
  performance underneath. Band-limit *first*, then measure.
- **Don't infer the content of a recording from the aligner's own output.** The
  22s "spoken intro" entered the record that way and then justified a design.

## Verification

- `test/galopede_teacher_demo_align_test.dart` — was print-only diagnostics;
  now a real regression test asserting 33 monotonic anchors, each ground-truth
  section boundary within 1.5s (~one measure, about the precision the by-ear
  timings have), and a final anchor inside the tune rather than in the
  loop-back. Mean error 0.60s. Skips where the gitignored fixtures are absent.
- `test/dtw_align_test.dart` — new `skip penalty calibration` group: a trailing
  run cheaper than the penalty is kept, a dearer one dropped, and a near-free
  penalty is shown collapsing a 21-frame target onto its single best-matching
  frame. Plus the interior-gap routing test described above. All pre-existing
  assertions unchanged.
- `test/audio_chroma_features_test.dart` — pure-tone mapping tests now pass
  `noiseSubtractionFactor: 0` (with the reasoning inline); new tests cover a
  note present in only part of a recording surviving subtraction, and a hum at
  20x a note's amplitude failing to outvote it.
- `test/audio_sync_playback_service_test.dart` — new `dropDegenerateSegments`
  group. This file previously tested only `sortAnchors`; the interpolation and
  bracketing logic still has no direct coverage.
- `test/lightly_row_intro_align_test.dart` — NEW, and the reason the penalty
  is 0.18 rather than 0.25. Asserts that the first segment paces like the rest
  of the piece, which catches anchor 0 being pulled into an intro without
  needing a hand-labelled first-note timestamp. Depends on the gitignored
  `assets/audio/`; skips where absent.
- `test/synthetic_alignment_robustness_test.dart` — NEW, and the only
  alignment test that runs on a fresh clone: it synthesizes its recordings
  from the score, so ground truth is exact and no gitignored fixture is
  needed. 13 conditions crossing intro kind (silent / unrelated / quotes the
  tune), outro kind (silent / loops back), hum level, in-band SNR and tempo.
  Asserts worst-case anchor-0 error under 0.25s; the default achieves 0.05s.
- `test/salt_creek_auto_align_test.dart` — unchanged assertions, all passing,
  with the improvements quoted above. Its `hasCompressedAnchors` is still
  `true`, which is now a **known false positive**: the same run puts all 32
  anchors within 100ms of a real onset. The detector was left alone (one sample
  is not enough to retune it safely, and it guards a real score bug) but
  `alignmentReviewMessage` no longer blames the score outright.

## Residual exposure

Worth being honest about, since this rests on a small sample:

- **Three real recordings**, all gitignored, and one tuned scalar
  (`skipPenaltyPerFrame`) carrying much of the load. The synthetic suite
  widens the evidence for its lower edge but not its upper edge.
- **`noiseSubtractionFactor` (1.5) and `noisePercentile` (0.10)** are my
  values, and their benefit is demonstrated on exactly one recording —
  Lightly Row is indifferent to the front end (old features with the new
  penalty give the same anchor 0). The band change is the part that is
  physics-derived rather than fitted.
- **The structural fix would be to stop inferring where the music starts.**
  Asking the user for the timecode of the first note (and optionally the
  last) removes the one decision that puts Galopede and Lightly Row in
  conflict, and would let the tempo estimate use the real music span instead
  of the whole recording's duration — the non-circular version of a fix
  dropped earlier for want of a sound way to compute it. A manual
  "intro seconds" field was considered and rejected in
  [audio-sync-dtw-open-boundaries.md](audio-sync-dtw-open-boundaries.md) as
  needing per-recording tuning; that judgement predates knowing that the
  automatic decision is genuinely ambiguous from the audio alone, and for a
  teacher demo the user has just watched themselves record it.

*Measured against the real `docs/photos_no_share/galopede_audio.wav`,
`assets/audio/lightly_row/melody.wav` and `assets/audio/salt_creek/melody.wav`,
2026-09-15.*

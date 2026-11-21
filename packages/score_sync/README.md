# score_sync

Score-to-recording alignment in pure Dart, with no Flutter and no platform
code: given a score and a recording of it, where in the recording each bar
starts.

- **`ScoreAligner<S>`:** aligns a recording (WAV bytes, or mono samples at
  any rate) to a score of your own type `S`. It only needs a `ScoreTiming<S>`,
  a function that lays the score out in time at a tempo (`TimedScore`: notes
  with onset, offset and MIDI pitch, and bar onsets). Returns
  `ScoreAudioAnchor`s (score milliseconds ↔ audio seconds), one per bar plus
  any the pause pass adds.
- **The parts:** `AudioChromaExtractor` (chroma and onsets from audio, with
  its frequency band as parameters), `ScoreChromaReferenceBuilder` (the same
  from the score, with `ringSeconds` for how long notes ring into rests),
  and `DtwAligner` (open-ended DTW with onset, step and skip terms).
- **Count-in:** `barCounting`, `countInPlan`, `countInUnitSeconds`.
- **Calibration:** the click pattern and its matcher (`sync_calibration`).

The defaults are tuned on violin. Other instruments want other values for
the chroma band, `ringSeconds` and the onset weight
(`docs/family/approach.md`, Part 2).

Written for [Stringlings](../../README.md), and extracted from it
(`docs/libraries-migration.md`). Licence: GPL-3.0.

Tests: `dart test` here, or `bash scripts/test_all.sh` from the repo root.

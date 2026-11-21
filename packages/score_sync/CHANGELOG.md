## Unreleased

- `AlignmentProfile`: the per-instrument parameters (chroma band,
  `ringSeconds`, onset weight) in one value. `ScoreAligner` takes it as
  `profile` (default `AlignmentProfile.bowedStrings`, today's values exactly)
  and hands it to the extractor, the reference builder and the DTW. Its
  `ringSeconds` parameter is gone: it is the profile's now.

## 0.1.0

- First version, moved out of Stringlings: `AudioChromaExtractor`,
  `ScoreChromaReferenceBuilder`, `DtwAligner`, `ScoreAligner` (generic over
  the score type, through `ScoreTiming`), `AudioEnergyEnvelope`, the
  count-in math and the sync-calibration click pattern.

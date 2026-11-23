## Unreleased

- `PitchTracker`'s frame size defaults to `PitchTracker.frameSizeFor` its
  detector: 2048 samples, doubled until the detector's range fits, so a cello
  (C2, a 43 Hz floor) gets 4096 instead of an `ArgumentError`.
  `tool/low_register_probe.dart` measures the choice.

## 0.2.0

- Renamed from `string_tuner`: it is growing beyond strings (chromatic
  targets, transposition), and the name now says so.
- `TunerModel`, `TunerFrame`, `TunerReading`, `TunerTrend`, `TunerDecision`
  and `UnisonMeter`, moved in from the Stringlings app with their tests.
- Chromatic and single-note targets (`InstrumentTuning.chromatic`,
  `InstrumentTuning.note`, `TargetKind`).
- `Transposition`: written pitch for transposing instruments.
- `DroneTone`: a seamless loop of a target pitch, and `encodeWav16`.

## 0.1.0

- First version: `YinDetector`, `PitchTracker`, `InstrumentTuning` (violin,
  viola, cello, mandolin; pure fifths or equal temperament; any reference A),
  `StringFollower`.

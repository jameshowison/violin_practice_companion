# string_tuner

Pitch detection and string tuning in pure Dart, with no dependencies and no
platform code, so it runs anywhere Dart does: Flutter on iOS, Android, macOS
and the web, or a command-line tool.

- **`YinDetector`**: the YIN pitch estimator, limited to a frequency range.
- **`PitchTracker`**: cuts a live sample stream into overlapping frames, in
  whatever chunk sizes a microphone plugin delivers, and reads each one. It
  also takes 16-bit PCM bytes directly.
- **`InstrumentTuning`**: open-string targets for violin, viola, cello and
  mandolin (or any strings you give it), from any reference A, in **pure
  fifths** (as string players tune by ear) or **equal temperament** (for
  fretted instruments).
- **`StringFollower`**: works out which string is being played without
  flickering between strings on one stray reading, or measures against a
  string the player has picked.

Written for the tuner in [Stringlings](../../README.md).

## Example

```dart
import 'package:string_tuner/string_tuner.dart';

final tuning = InstrumentTuning.violin(a4: 442);
final range = tuning.detectionRange;
final tracker = PitchTracker(
  YinDetector(sampleRate: 48000, minHz: range.minHz, maxHz: range.maxHz),
  frameSize: 2048, // ~43 ms at 48 kHz
  hopSize: 512,    // a reading every ~11 ms
);
final follower = StringFollower(tuning);

// For each chunk from the microphone (e.g. `record`'s startStream with
// AudioEncoder.pcm16bits, 48 kHz, mono):
for (final reading in tracker.addPcm16(chunk)) {
  final pitch = reading.pitch;
  if (pitch == null || pitch.clarity < 0.85) continue; // silence or noise
  final r = follower.update(pitch.hz);
  print('${r.string.name} ${r.cents.toStringAsFixed(1)} cents');
}
```

### Off the UI thread

`detect` is synchronous: about 0.6 ms per 2048-sample frame over a violin's
range, compiled, on an Apple-silicon Mac. At a reading every 512 samples that
is ~6% of one core, which is enough to drop UI frames on a slow phone. In a
Flutter app, run the tracker in a long-lived isolate and send it the
microphone chunks. On the web, where there are no isolates, use a larger hop.

## Choices

- **The search range is limited.** The cost of YIN's difference function is
  frame length × longest period, so searching only the instrument's range
  (`detectionRange`: a fifth below the lowest string to an octave above the
  highest) halves the work compared with searching from 47 Hz. It also rules
  out octave errors below the range.
- **The threshold is a parameter**, defaulting to 0.12, inside the 0.10–0.15
  that the YIN paper recommends. A looser threshold accepts an early dip, which
  on a string with a weak fundamental (a violin's G often has one) reads an
  octave high.
- **Always an answer, with a confidence.** When no dip is under the threshold,
  the deepest one is returned with its low `clarity`. The caller decides what
  to trust. Frames under `minRms` return null.
- **Pure fifths are the default for bowed strings.** Against A = 440, a
  violin tuned by ear has G at 195.56 Hz, about 4 cents under its
  equal-tempered 196.00. A tuner aiming at 196.00 would call a correctly
  tuned G sharp.

YIN's sixth step (the "best local estimate") is not implemented. On the test
signals, including a tone whose fundamental is a quarter of its second
harmonic, the estimate is within 1 cent without it.

## Tests

```bash
dart test                                    # tests on synthetic tones
dart compile exe tool/bench.dart -o /tmp/bench && /tmp/bench   # timing
dart run tool/eval_corpus.dart <dir>         # score recordings, see below
```

`tool/eval_corpus.dart` scores recordings labelled by a reference tuner. The
directory holds the audio (WAV, or anything macOS's `afconvert` reads) and a
`takes.csv` with columns `file,instrument,string,ref_cents,ref_a4,note`. Leave
`string` empty for a free tuning session, which gets a timeline of the strings
followed instead of a score. Optional `start_s` and `end_s` columns cut takes
out of one long recording that starts with three short 3 kHz beeps; the script
finds the beeps and counts from the first. The column meanings are at the top
of the script.

## Status

0.1.0, unpublished. It lives in the Stringlings repository until the app's
tuner has been tried against real instruments. After that it can move to its
own repository and be published to pub.dev.

## Credits

- The YIN algorithm: A. de Cheveigné and H. Kawahara, "YIN, a fundamental
  frequency estimator for speech and music", *J. Acoust. Soc. Am.* 111(4),
  2002.
- Written with reference to
  [`pitch_detector_dart`](https://pub.dev/packages/pitch_detector_dart) by
  Lucas Bento (BSD-3-Clause), itself a port of the YIN implementation in
  Joren Six's [TarsosDSP](https://github.com/JorenSix/TarsosDSP). No code is
  copied from either. The structure of the steps and the parabolic
  interpolation follow the paper.

## Licence

BSD-3-Clause; see [LICENSE](LICENSE).

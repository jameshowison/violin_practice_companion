import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pitch_tuner/pitch_tuner.dart';
import 'package:test/test.dart';

const sr = 48000.0;

/// One second of a bowed-string-like tone at [hz] under white noise of peak
/// [noise] (0.01 is about 34 dB under the tone).
Float32List bowed(double hz, {double noise = 0.01, int seed = 1}) {
  const amps = [1.0, 0.7, 0.5, 0.35, 0.25, 0.15, 0.1];
  final norm = amps.fold<double>(0, (a, b) => a + b);
  final rnd = math.Random(seed);
  return Float32List.fromList([
    for (var i = 0; i < sr; i++)
      0.5 / norm *
              [
                for (var k = 0; k < amps.length; k++)
                  amps[k] * math.sin(2 * math.pi * hz * (k + 1) * i / sr + 0.3 * (k + 1))
              ].fold<double>(0, (a, b) => a + b) +
          noise * (rnd.nextDouble() * 2 - 1),
  ]);
}

YinDetector detectorFor(InstrumentTuning t) {
  final r = t.detectionRange;
  return YinDetector(sampleRate: sr, minHz: r.minHz, maxHz: r.maxHz);
}

void main() {
  group('frameSizeFor', () {
    test('2048 samples for the violin, viola and mandolin', () {
      for (final t in [
        InstrumentTuning.violin(),
        InstrumentTuning.viola(),
        InstrumentTuning.mandolin(),
      ]) {
        expect(PitchTracker.frameSizeFor(detectorFor(t)), 2048, reason: t.name);
      }
    });

    test('4096 for the cello, whose range reaches down to 43 Hz', () {
      final yin = detectorFor(InstrumentTuning.cello());
      expect(yin.minFrameLength, greaterThan(2048));
      expect(PitchTracker.frameSizeFor(yin), 4096);
      expect(PitchTracker(yin).frameSize, 4096);
    });

    test('an explicit frame size is still honoured', () {
      final yin = detectorFor(InstrumentTuning.violin());
      expect(PitchTracker(yin, frameSize: 4096).frameSize, 4096);
    });

    test('an explicit frame too short for the range still throws', () {
      final yin = detectorFor(InstrumentTuning.cello());
      expect(() => PitchTracker(yin, frameSize: 2048), throwsArgumentError);
    });
  });

  test('a cello tracker reads every open string within a cent', () {
    final cello = InstrumentTuning.cello();
    for (final s in cello.strings) {
      for (final off in [-30.0, 0.0, 30.0]) {
        final hz = s.hz * math.pow(2, off / 1200);
        final cents = [
          for (final r in PitchTracker(detectorFor(cello)).addSamples(bowed(hz)))
            centsBetween(r.pitch!.hz, hz)
        ]..sort();
        expect(cents[cents.length ~/ 2].abs(), lessThan(1),
            reason: '${s.name} ${off.toInt()} cents');
        expect(cello.nearest(hz).name, s.name);
      }
    }
  });
}

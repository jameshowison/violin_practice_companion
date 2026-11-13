import 'dart:math' as math;
import 'dart:typed_data';

import 'package:string_tuner/string_tuner.dart';
import 'package:test/test.dart';

const sr = 48000.0;

/// A harmonic tone: [amps][k] is the amplitude of harmonic k + 1.
Float32List tone(double hz, List<double> amps,
    {int n = 2048, double noise = 0, double decay = 0, double phase = 0.3, int seed = 1}) {
  final rnd = math.Random(seed);
  final out = Float32List(n);
  final norm = amps.fold<double>(0, (a, b) => a + b);
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    var v = 0.0;
    for (var k = 0; k < amps.length; k++) {
      v += amps[k] * math.sin(2 * math.pi * hz * (k + 1) * t + phase * (k + 1));
    }
    v = 0.5 * v / norm * math.exp(-decay * t);
    if (noise > 0) v += noise * (rnd.nextDouble() * 2 - 1);
    out[i] = v;
  }
  return out;
}

// A bowed-string-like spectrum whose fundamental is weaker than its second
// and third harmonics, as on many violins' G strings.
const weakFundamental = [0.25, 1.0, 0.8, 0.6, 0.5, 0.4, 0.3, 0.2, 0.15, 0.1];

void main() {
  final violin = InstrumentTuning.violin();
  final range = violin.detectionRange;
  final yin = YinDetector(sampleRate: sr, minHz: range.minHz, maxHz: range.maxHz);

  group('accuracy', () {
    for (final s in violin.strings) {
      test('pure sine at ${s.name}', () {
        final e = yin.detect(tone(s.hz, [1]))!;
        expect(centsBetween(e.hz, s.hz).abs(), lessThan(0.5));
        expect(e.clarity, greaterThan(0.95));
      });
      test('weak fundamental at ${s.name} is not an octave out', () {
        final e = yin.detect(tone(s.hz, weakFundamental))!;
        expect(centsBetween(e.hz, s.hz).abs(), lessThan(1.0));
      });
    }

    test('resolves a 2-cent offset at every string', () {
      for (final s in violin.strings) {
        final hz = s.hz * math.pow(2, 2 / 1200);
        final e = yin.detect(tone(hz, weakFundamental))!;
        expect(centsBetween(e.hz, s.hz), closeTo(2, 0.6), reason: s.name);
      }
    });

    test('holds up under noise at about 20 dB SNR', () {
      final e = yin.detect(tone(293.33, weakFundamental, noise: 0.05))!;
      expect(centsBetween(e.hz, 293.33).abs(), lessThan(2));
    });

    test('a decaying pluck (mandolin-like) still reads', () {
      final e = yin.detect(tone(659.26, [1, 0.6, 0.3, 0.2], decay: 6))!;
      expect(centsBetween(e.hz, 659.26).abs(), lessThan(1));
    });
  });

  group('rejection', () {
    test('silence returns null', () {
      expect(yin.detect(Float32List(2048)), isNull);
    });

    test('white noise reads as unclear', () {
      final rnd = math.Random(7);
      final f = Float32List.fromList(List.generate(2048, (_) => rnd.nextDouble() - 0.5));
      final e = yin.detect(f)!;
      expect(e.clarity, lessThan(0.7));
    });

    test('too short a frame throws', () {
      expect(() => yin.detect(Float32List(yin.minFrameLength - 1)), throwsArgumentError);
    });
  });

  test('cost per 2048-sample frame, violin range (informational)', () {
    final f = tone(440, weakFundamental);
    for (var i = 0; i < 50; i++) {
      yin.detect(f);
    }
    final sw = Stopwatch()..start();
    const runs = 400;
    for (var i = 0; i < runs; i++) {
      yin.detect(f);
    }
    final us = sw.elapsedMicroseconds / runs;
    // ignore: avoid_print
    print('YIN, tau ${yin.tauMin}..${yin.tauMax}: ${us.toStringAsFixed(0)} µs per frame');
  });
}

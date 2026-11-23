// How well the tracker reads an instrument's open strings, by frame size and
// noise: the measurement behind PitchTracker.frameSizeFor.
//
//   dart run tool/low_register_probe.dart            # cello, 2048..8192
//   dart run tool/low_register_probe.dart violin     # violin, for a baseline
//
// Each row is one string at one frame size and noise level, over three noise
// seeds: the median error of a second of readings (a bias), and the 90th
// percentile of its size (the scatter the tuner's smoothing has to absorb).
// A frame too short for the range is tried with the floor raised to fit it.
// ignore_for_file: avoid_print
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pitch_tuner/pitch_tuner.dart';

const sr = 48000.0;

/// [seconds] of a bowed-string-like tone (strong fundamental, falling
/// harmonics) under white noise of peak [noise]: 0.05 is about 20 dB under
/// the tone, 0.01 about 34 dB.
Float32List tone(double hz, {double seconds = 1, double noise = 0, int seed = 1}) {
  const amps = [1.0, 0.7, 0.5, 0.35, 0.25, 0.15, 0.1];
  final norm = amps.fold<double>(0, (a, b) => a + b);
  final rnd = math.Random(seed);
  final out = Float32List((seconds * sr).round());
  for (var i = 0; i < out.length; i++) {
    var v = 0.0;
    for (var k = 0; k < amps.length; k++) {
      v += amps[k] * math.sin(2 * math.pi * hz * (k + 1) * i / sr + 0.3 * (k + 1));
    }
    out[i] = 0.5 * v / norm + noise * (rnd.nextDouble() * 2 - 1);
  }
  return out;
}

void main(List<String> args) {
  final tuning = args.contains('violin') ? InstrumentTuning.violin() : InstrumentTuning.cello();
  final range = tuning.detectionRange;
  for (final n in [2048, 4096, 6144, 8192]) {
    var yin = YinDetector(sampleRate: sr, minHz: range.minHz, maxHz: range.maxHz);
    if (yin.minFrameLength > n) {
      // The longest period that fits: a frame of two periods and two samples.
      yin = YinDetector(sampleRate: sr, minHz: sr / ((n - 2) ~/ 2), maxHz: range.maxHz);
    }
    final floor = 'floor ${yin.minHz.toStringAsFixed(1)} Hz';
    for (final noise in [0.05, 0.01]) {
      for (final s in tuning.strings) {
        final row = <String>[];
        for (final seed in [1, 2, 3]) {
          final t = PitchTracker(yin, frameSize: n);
          final cents = [
            for (final r in t.addSamples(tone(s.hz, noise: noise, seed: seed)))
              if (r.pitch != null) centsBetween(r.pitch!.hz, s.hz)
          ]..sort();
          final size = cents.map((c) => c.abs()).toList()..sort();
          row.add('median ${cents[cents.length ~/ 2].toStringAsFixed(2)}c '
              'p90 ${size[(size.length * 0.9).floor()].toStringAsFixed(1)}c');
        }
        print('n=$n ($floor) noise $noise ${s.name}: ${row.join('; ')}');
      }
    }
  }
}

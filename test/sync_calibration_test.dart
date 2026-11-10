import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/sync_calibration.dart';

/// What the native capture would report if the clip were heard [delay]
/// seconds late at [gain], over room noise of [noise] (rms), with the clicks
/// at [drop] missing — high-passed energy in 1ms slices, as the Swift does.
MicEnvelope hear({
  required double delay,
  double gain = 0.3,
  double noise = 0.002,
  Set<int> drop = const {},
  double captureStart = 1000.0,
  double playerZero = 1000.4,
}) {
  const sr = 48000;
  final clip = CalibrationClip.samples();
  final clipSr = CalibrationClip.sampleRate;
  final seconds = CalibrationClip.durationSeconds + 3.5;
  final n = (seconds * sr).round();
  final rnd = math.Random(7);
  final x = Float64List(n);
  final dropped = <(int, int)>[
    for (final i in drop)
      (
        (CalibrationClip.clickTimes[i] * clipSr).round(),
        ((CalibrationClip.clickTimes[i] + 0.02) * clipSr).round()
      )
  ];
  for (var i = 0; i < n; i++) {
    final t = captureStart + i / sr; // wall time of this mic sample
    final clipT = t - playerZero - delay;
    var v = noise * (rnd.nextDouble() * 2 - 1) * math.sqrt(3);
    final j = (clipT * clipSr).floor();
    if (j >= 0 && j < clip.length &&
        !dropped.any((d) => j >= d.$1 && j < d.$2)) {
      v += gain * clip[j];
    }
    x[i] = v;
  }
  const hop = 48;
  final env = <double>[];
  var prev = 0.0, acc = 0.0;
  for (var i = 0; i < n; i++) {
    final d = x[i] - prev;
    prev = x[i];
    acc += d * d;
    if ((i + 1) % hop == 0) {
      env.add(acc / hop);
      acc = 0;
    }
  }
  return MicEnvelope(
      startSeconds: captureStart, hopSeconds: hop / sr, energy: env);
}

List<double> expectedFrom(double playerZero) =>
    [for (final c in CalibrationClip.clickTimes) playerZero + c];

void main() {
  test('the clip is a valid WAV with a click at each listed time', () {
    final wav = CalibrationClip.wavBytes();
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    final s = CalibrationClip.samples();
    for (final t in CalibrationClip.clickTimes) {
      final i = (t * CalibrationClip.sampleRate).round();
      final peak = s.sublist(i, i + 40).map((v) => v.abs()).reduce(math.max);
      expect(peak, greaterThan(0.3), reason: 'click at $t');
      expect(s[i - 5].abs(), 0, reason: 'silence before $t');
    }
  });

  for (final delay in [0.012, 0.18, 0.31, 2.05]) {
    test('measures a ${(delay * 1000).round()}ms delay to within 2ms', () {
      final r = measureDelay(expectedFrom(1000.4), hear(delay: delay));
      expect(r.ok, isTrue, reason: '$r');
      expect(r.delaySeconds!, closeTo(delay, 0.002), reason: '$r');
      expect(r.clicksHeard, CalibrationClip.clickTimes.length);
    });
  }

  test('a negative delay (player position running behind) is measured too',
      () {
    final r = measureDelay(expectedFrom(1000.4), hear(delay: -0.08));
    expect(r.delaySeconds!, closeTo(-0.08, 0.002), reason: '$r');
  });

  test('survives a few missed clicks', () {
    final r = measureDelay(
        expectedFrom(1000.4), hear(delay: 0.2, drop: {0, 4, 7}));
    expect(r.ok, isTrue, reason: '$r');
    expect(r.delaySeconds!, closeTo(0.2, 0.002));
    expect(r.clicksHeard, CalibrationClip.clickTimes.length - 3);
  });

  test('a quiet speaker in a noisy room fails rather than guessing', () {
    final r = measureDelay(
        expectedFrom(1000.4), hear(delay: 0.2, gain: 0.002, noise: 0.01));
    expect(r.ok, isFalse);
    expect(r.failure, isNotNull);
  });

  test('silence fails', () {
    final r = measureDelay(
        expectedFrom(1000.4), hear(delay: 0.2, gain: 0, noise: 0.002));
    expect(r.ok, isFalse);
  });

  test('player zero is the median of wall-minus-position', () {
    final samples = [
      (10.0, 0.0), // stale reading just after play()
      for (var i = 1; i <= 20; i++) (10.0 + i * 0.01, 0.4 + i * 0.01 - 0.4),
    ];
    expect(playerZeroWallSeconds(samples), closeTo(10.0, 1e-9));
    expect(playerZeroWallSeconds(const [(1.0, 0.5)]), isNull);
  });
}

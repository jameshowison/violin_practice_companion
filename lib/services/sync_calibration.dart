import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The calibration clip: a few sharp clicks at deliberately irregular times,
/// so that the pattern lines up with what the mic heard at exactly one delay
/// (evenly spaced clicks would line up at every multiple of the spacing, and
/// AirPlay's ~2s delay is several spacings).
///
/// Pure data: the WAV bytes and the click times within them. Played through
/// the same kind of player as a recording, so what is measured is that
/// player's own position-to-heard delay — see [SyncCalibrator].
@immutable
class CalibrationClip {
  static const sampleRate = 44100;

  /// Click onsets, seconds into the clip. The first second is silence: a
  /// Bluetooth speaker that has been idle can swallow the start of a stream
  /// while it wakes up.
  static const clickTimes = <double>[
    1.00, 1.37, 1.91, 2.30, 2.98, 3.41, 3.83, 4.52, 4.95, 5.60, //
  ];

  static const durationSeconds = 5.9;

  /// One click: a 2.5 kHz tone with an instant attack and a 2ms decay — a
  /// hard edge for the onset, at a pitch every speaker and mic handles.
  static const _clickHz = 2500.0;
  static const _decaySeconds = 0.002;
  static const _clickSeconds = 0.015;

  const CalibrationClip._();

  /// The clip as mono 16-bit PCM samples in [-1, 1].
  static Float64List samples() {
    final n = (durationSeconds * sampleRate).round();
    final out = Float64List(n);
    final len = (_clickSeconds * sampleRate).round();
    for (final t in clickTimes) {
      final start = (t * sampleRate).round();
      for (var i = 0; i < len && start + i < n; i++) {
        final s = i / sampleRate;
        out[start + i] =
            0.8 * math.sin(2 * math.pi * _clickHz * s) * math.exp(-s / _decaySeconds);
      }
    }
    return out;
  }

  /// The clip as a complete WAV file.
  static Uint8List wavBytes() => _wav(samples());

  /// [seconds] of silence as a WAV file — played before calibrating, to wake
  /// a speaker (AirPlay especially) whose stream has gone idle.
  static Uint8List silenceWavBytes(double seconds) =>
      _wav(Float64List((seconds * sampleRate).round()));

  static Uint8List _wav(Float64List pcm) {
    final dataLen = pcm.length * 2;
    final b = ByteData(44 + dataLen);
    void ascii(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    b.setUint32(4, 36 + dataLen, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    b.setUint32(40, dataLen, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      b.setInt16(44 + i * 2, (pcm[i].clamp(-1.0, 1.0) * 32767).round(),
          Endian.little);
    }
    return b.buffer.asUint8List();
  }
}

/// What the mic heard, as the native capture reports it: the high-passed
/// energy in consecutive [hopSeconds] slices, the first of which began at
/// wall-clock second [startSeconds] (the same clock as `DateTime.now()`).
@immutable
class MicEnvelope {
  final double startSeconds;
  final double hopSeconds;
  final List<double> energy;

  const MicEnvelope({
    required this.startSeconds,
    required this.hopSeconds,
    required this.energy,
  });

  double timeOf(int hop) => startSeconds + hop * hopSeconds;
  int hopAt(double t) => ((t - startSeconds) / hopSeconds).floor();
}

@immutable
class CalibrationResult {
  /// Seconds from the player reaching a click to the mic hearing it, or null
  /// when the measurement failed ([failure] says why).
  final double? delaySeconds;
  final int clicksHeard;
  final int clicksPlayed;

  /// Median absolute deviation of the per-click delays.
  final double spreadSeconds;
  final String? failure;

  const CalibrationResult({
    required this.delaySeconds,
    required this.clicksHeard,
    required this.clicksPlayed,
    required this.spreadSeconds,
    this.failure,
  });

  const CalibrationResult.failed(this.failure,
      {this.clicksHeard = 0, this.clicksPlayed = 0})
      : delaySeconds = null,
        spreadSeconds = 0;

  bool get ok => delaySeconds != null;

  @override
  String toString() => ok
      ? 'delay=${(delaySeconds! * 1000).round()}ms '
          'heard=$clicksHeard/$clicksPlayed '
          'spread=${(spreadSeconds * 1000).toStringAsFixed(1)}ms'
      : 'failed: $failure (heard=$clicksHeard/$clicksPlayed)';
}

/// Finds the delay between [expected] (wall-clock seconds at which the player
/// reached each click) and when [mic] heard them.
///
/// Two passes: the whole click pattern is slid across the mic's onset
/// strength to find the one lag where it all lines up (coarse, robust to a
/// missed click or a cough), then each click's own onset is timed near that
/// lag, and the median taken.
CalibrationResult measureDelay(
  List<double> expected,
  MicEnvelope mic, {
  double minLag = -0.3,
  double maxLag = 2.5,
}) {
  final n = mic.energy.length;
  if (n < 50 || expected.isEmpty) {
    return CalibrationResult.failed('the mic recorded nothing',
        clicksPlayed: expected.length);
  }
  final db = [for (final e in mic.energy) 10 * math.log(e + 1e-12) / math.ln10];

  // Onset strength: how far each slice rises above the slices just before it.
  final hopsBack = math.max(2, (0.02 / mic.hopSeconds).round());
  final gap = math.max(1, (0.004 / mic.hopSeconds).round());
  final onset = Float64List(n);
  for (var i = hopsBack + gap; i < n; i++) {
    var sum = 0.0;
    for (var j = i - hopsBack - gap; j < i - gap; j++) {
      sum += db[j];
    }
    onset[i] = math.max(0, db[i] - sum / hopsBack);
  }

  double strengthNear(double t) {
    final c = mic.hopAt(t);
    var best = 0.0;
    for (var i = c - 2; i <= c + 2; i++) {
      if (i >= 0 && i < n && onset[i] > best) best = onset[i];
    }
    return best;
  }

  var bestLag = 0.0, bestScore = -1.0;
  for (var lag = minLag; lag <= maxLag; lag += mic.hopSeconds) {
    var score = 0.0;
    for (final e in expected) {
      score += strengthNear(e + lag);
    }
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }

  // Time each click: the first slice in a ±30ms window that climbs halfway
  // (in dB) from the quiet before it to the click's peak.
  final delays = <double>[];
  for (final e in expected) {
    final lo = mic.hopAt(e + bestLag - 0.03), hi = mic.hopAt(e + bestLag + 0.03);
    final floorFrom = mic.hopAt(e + bestLag - 0.13);
    if (floorFrom < 0 || hi >= n) continue;
    final quiet = [for (var i = floorFrom; i < lo; i++) db[i]]..sort();
    final floor = quiet[quiet.length ~/ 2];
    var peak = double.negativeInfinity;
    for (var i = lo; i <= hi; i++) {
      peak = math.max(peak, db[i]);
    }
    if (peak - floor < 12) continue; // not heard over the room
    final half = floor + (peak - floor) / 2;
    for (var i = lo; i <= hi; i++) {
      if (db[i] >= half) {
        delays.add(mic.timeOf(i) - e);
        break;
      }
    }
  }

  final played = expected.length;
  final needed = (played * 0.6).ceil();
  if (delays.length < needed) {
    return CalibrationResult.failed(
        delays.isEmpty
            ? "couldn't hear the clicks — turn the speaker up"
            : 'heard too few clicks — turn the speaker up or try somewhere quieter',
        clicksHeard: delays.length,
        clicksPlayed: played);
  }
  delays.sort();
  final median = delays[delays.length ~/ 2];
  final dev = [for (final d in delays) (d - median).abs()]..sort();
  final spread = dev[dev.length ~/ 2];
  if (spread > 0.015) {
    return CalibrationResult.failed('the clicks came back unevenly — try again',
        clicksHeard: delays.length, clicksPlayed: played);
  }
  return CalibrationResult(
    delaySeconds: median,
    clicksHeard: delays.length,
    clicksPlayed: played,
    spreadSeconds: spread,
  );
}

/// The wall-clock second at which a player's position read zero, from
/// `(wallSeconds, positionSeconds)` samples taken while it played at 1×. The
/// median, so the stale readings just after `play()` don't skew it.
double? playerZeroWallSeconds(List<(double, double)> samples) {
  if (samples.length < 5) return null;
  final z = [for (final (w, p) in samples) w - p]..sort();
  return z[z.length ~/ 2];
}

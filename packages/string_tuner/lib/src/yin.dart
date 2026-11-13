import 'dart:math' as math;
import 'dart:typed_data';

/// One pitch estimate from one frame of audio.
class PitchEstimate {
  const PitchEstimate({
    required this.hz,
    required this.clarity,
    required this.rms,
  });

  /// The fundamental frequency, in hertz.
  final double hz;

  /// How periodic the frame is, from 0 (noise) to 1 (a pure tone): one minus
  /// YIN's normalised difference at the chosen period. A bowed or plucked
  /// string usually reads above 0.85; below about 0.7 the estimate is
  /// unreliable.
  final double clarity;

  /// Root-mean-square level of the frame, after removing its DC offset, on
  /// the same scale as the samples (1.0 is full scale for float audio).
  final double rms;

  @override
  String toString() =>
      'PitchEstimate(${hz.toStringAsFixed(2)} Hz, clarity ${clarity.toStringAsFixed(3)}, rms ${rms.toStringAsFixed(4)})';
}

/// The YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002),
/// restricted to a frequency range.
///
/// Synchronous and allocation-free after construction, so it can run on any
/// isolate, including on the web. Calling it on the UI isolate is possible
/// but wasteful for overlapping frames; real-time apps should feed it from a
/// background isolate (see the package README).
///
/// Differences from a textbook YIN, and from `pitch_detector_dart`, which this
/// package was written with reference to:
///
/// * The search covers only periods between [minHz] and [maxHz]. That makes
///   the difference function cheaper (its cost is frame length × longest
///   period) and rules out octave errors below the instrument's range.
/// * The threshold is a parameter, defaulting to 0.12, inside the paper's
///   recommended 0.10–0.15.
/// * When no dip falls under the threshold, the deepest dip in range is still
///   returned, with its low [PitchEstimate.clarity], so the caller decides
///   what to trust rather than getting nothing.
/// * Frames quieter than [minRms] return null without being analysed.
class YinDetector {
  YinDetector({
    required this.sampleRate,
    this.minHz = 60,
    this.maxHz = 2000,
    this.threshold = 0.12,
    this.minRms = 0.002,
  })  : assert(sampleRate > 0),
        assert(minHz > 0 && maxHz > minHz),
        assert(threshold > 0 && threshold < 1),
        tauMin = math.max(2, (sampleRate / maxHz).floor()),
        tauMax = (sampleRate / minHz).ceil() {
    _d = Float64List(tauMax + 2);
  }

  /// Samples per second of the audio passed to [detect].
  final double sampleRate;

  /// Lowest and highest frequency searched, in hertz.
  final double minHz, maxHz;

  /// YIN's absolute threshold on the normalised difference function.
  final double threshold;

  /// Frames below this RMS level are treated as silence.
  final double minRms;

  /// Shortest and longest period searched, in samples.
  final int tauMin, tauMax;

  late final Float64List _d;

  /// The shortest frame [detect] accepts: two of the longest period, so the
  /// integration window is at least one period long.
  int get minFrameLength => 2 * tauMax + 2;

  /// Estimates the pitch of [frame], or returns null if it is too quiet.
  ///
  /// [frame] must hold at least [minFrameLength] samples. Its integration
  /// window is `frame.length - tauMax - 1` samples; longer frames give
  /// steadier estimates at the cost of time resolution and work.
  PitchEstimate? detect(Float32List frame) {
    final n = frame.length;
    if (n < minFrameLength) {
      throw ArgumentError.value(
          n, 'frame.length', 'must be at least $minFrameLength samples');
    }

    // Level, with the DC offset removed. The difference function is immune
    // to DC, so the mean is only needed here.
    var mean = 0.0;
    for (var i = 0; i < n; i++) {
      mean += frame[i];
    }
    mean /= n;
    var power = 0.0;
    for (var i = 0; i < n; i++) {
      final v = frame[i] - mean;
      power += v * v;
    }
    final rms = math.sqrt(power / n);
    if (rms < minRms) return null;

    // Step 2: the difference function, for every period up to tauMax + 1
    // (the extra one feeds the parabolic interpolation).
    final d = _d;
    final w = n - tauMax - 1;
    d[0] = 0;
    for (var tau = 1; tau <= tauMax + 1; tau++) {
      var sum = 0.0;
      for (var j = 0; j < w; j++) {
        final delta = frame[j] - frame[j + tau];
        sum += delta * delta;
      }
      d[tau] = sum;
    }

    // Step 3: cumulative mean normalised difference, in place.
    d[0] = 1;
    var running = 0.0;
    for (var tau = 1; tau <= tauMax + 1; tau++) {
      running += d[tau];
      d[tau] = running == 0 ? 1 : d[tau] * tau / running;
    }

    // Step 4: the first dip under the threshold, followed to its bottom.
    // Failing that, the deepest dip in range.
    var best = -1;
    for (var tau = tauMin; tau <= tauMax; tau++) {
      if (d[tau] < threshold) {
        while (tau + 1 <= tauMax && d[tau + 1] < d[tau]) {
          tau++;
        }
        best = tau;
        break;
      }
    }
    if (best < 0) {
      best = tauMin;
      for (var tau = tauMin + 1; tau <= tauMax; tau++) {
        if (d[tau] < d[best]) best = tau;
      }
    }

    // Step 5: parabolic interpolation around the chosen period.
    final s0 = d[best - 1], s1 = d[best], s2 = d[best + 1];
    final denom = s0 - 2 * s1 + s2;
    var period = best.toDouble();
    if (denom > 0) {
      final shift = 0.5 * (s0 - s2) / denom;
      if (shift.abs() < 1) period += shift;
    }

    return PitchEstimate(
      hz: sampleRate / period,
      clarity: (1 - s1).clamp(0.0, 1.0),
      rms: rms,
    );
  }
}

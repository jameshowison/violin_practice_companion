import 'dart:math' as math;
import 'dart:typed_data';

import 'package:wav/wav.dart';

/// A coarse amplitude-over-time envelope of a real recording — rectified RMS
/// energy per short frame. Cheaper than chroma/STFT (no FFT), and enough to
/// spot note attacks: useful both as a diagnostic (does a computed anchor
/// land near a real onset?) and, later, as the basis for a waveform display.
class EnergyEnvelope {
  final Float64List rms;
  final double hopSeconds;

  const EnergyEnvelope(this.rms, this.hopSeconds);
}

class AudioEnergyEnvelopeExtractor {
  final int frameSize;
  final int hopSize;

  const AudioEnergyEnvelopeExtractor({this.frameSize = 1024, this.hopSize = 441});

  EnergyEnvelope extractFromWavBytes(Uint8List wavBytes) {
    final wav = Wav.read(wavBytes);
    return extractFromSamples(wav.toMono(), wav.samplesPerSecond.toDouble());
  }

  EnergyEnvelope extractFromSamples(Float64List samples, double sampleRate) {
    final hopSeconds = hopSize / sampleRate;
    final frameCount = samples.isEmpty
        ? 0
        : ((samples.length - 1) / hopSize).floor() + 1;
    final rms = Float64List(frameCount);
    for (var f = 0; f < frameCount; f++) {
      final start = f * hopSize;
      final end = (start + frameSize).clamp(0, samples.length);
      var sumSq = 0.0;
      for (var i = start; i < end; i++) {
        sumSq += samples[i] * samples[i];
      }
      final n = end - start;
      rms[f] = n > 0 ? math.sqrt(sumSq / n) : 0;
    }
    return EnergyEnvelope(rms, hopSeconds);
  }

  /// Picks onset times as local maxima of the envelope's positive first
  /// difference (a rise in energy), above a threshold derived from the
  /// signal itself, at least [minSpacingSeconds] apart.
  List<double> detectOnsetTimes(
    EnergyEnvelope env, {
    double minSpacingSeconds = 0.08,
  }) {
    final rms = env.rms;
    if (rms.length < 3) return const [];
    final rise = Float64List(rms.length);
    for (var i = 1; i < rms.length; i++) {
      final d = rms[i] - rms[i - 1];
      rise[i] = d > 0 ? d : 0;
    }
    var mean = 0.0;
    for (final v in rise) {
      mean += v;
    }
    mean /= rise.length;
    var variance = 0.0;
    for (final v in rise) {
      variance += (v - mean) * (v - mean);
    }
    final stdDev = math.sqrt(variance / rise.length);
    final threshold = mean + stdDev;

    final minSpacingFrames = (minSpacingSeconds / env.hopSeconds).round();
    final onsets = <double>[];
    var lastOnsetFrame = -minSpacingFrames;
    for (var i = 1; i < rise.length - 1; i++) {
      if (rise[i] > threshold && rise[i] >= rise[i - 1] && rise[i] >= rise[i + 1]) {
        if (i - lastOnsetFrame >= minSpacingFrames) {
          onsets.add(i * env.hopSeconds);
          lastOnsetFrame = i;
        }
      }
    }
    return onsets;
  }
}

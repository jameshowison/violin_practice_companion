import 'dart:math' as math;
import 'dart:typed_data';

/// A tone to tune by ear against: a target pitch, sounded steadily.
///
/// It is rendered once, as a buffer that loops without a click, and is
/// meant to be played as a file by the app's ordinary player (with looping
/// on). It is never synthesised live: on iOS a live synth on an
/// AVAudioEngine does not follow a change of speaker (the app's CLAUDE.md,
/// "Audio on iOS").
class DroneTone {
  DroneTone._(this.samples, this.sampleRate, this.hz);

  /// Renders about [seconds] of [hz] at [sampleRate], with [harmonics]
  /// (relative amplitudes of the 1st, 2nd, … partials: a soft, reedy tone by
  /// default, so the ear has overtones to beat against), peaking at
  /// [amplitude].
  ///
  /// The buffer holds a whole number of cycles, so its end runs on into its
  /// start. To make that exact, the pitch is nudged to the nearest frequency
  /// that fits ([hz] on the result): under 0.1 cent from the target for any
  /// note above 40 Hz at the default two seconds.
  factory DroneTone.render(double targetHz,
      {int sampleRate = 48000,
      double seconds = 2,
      List<double> harmonics = const [1, 0.45, 0.2, 0.1],
      double amplitude = 0.3}) {
    if (targetHz <= 0 || targetHz >= sampleRate / 2) {
      throw ArgumentError.value(targetHz, 'targetHz', 'must be between 0 and Nyquist');
    }
    // Choose a sample count holding a whole number of cycles as close to
    // the target as a count can get.
    final cycles = math.max(1, (targetHz * seconds).round());
    final n = (cycles * sampleRate / targetHz).round();
    final hz = cycles * sampleRate / n;
    final out = Float32List(n);
    var peak = 0.0;
    for (var i = 0; i < n; i++) {
      final phase = 2 * math.pi * cycles * i / n;
      var v = 0.0;
      for (var h = 0; h < harmonics.length; h++) {
        if ((h + 1) * hz >= sampleRate / 2) break;
        v += harmonics[h] * math.sin((h + 1) * phase);
      }
      out[i] = v;
      if (v.abs() > peak) peak = v.abs();
    }
    if (peak > 0) {
      final k = amplitude / peak;
      for (var i = 0; i < n; i++) {
        out[i] *= k;
      }
    }
    return DroneTone._(out, sampleRate, hz);
  }

  /// One loop of the tone, mono, in −1..1.
  final Float32List samples;
  final int sampleRate;

  /// The pitch actually rendered: the target, nudged to fit the loop.
  final double hz;

  /// The loop as a 16-bit mono WAV file.
  Uint8List toWav() => encodeWav16(samples, sampleRate);
}

/// [samples] (mono, −1..1) as a 16-bit PCM WAV file.
Uint8List encodeWav16(Float32List samples, int sampleRate) {
  final dataBytes = samples.length * 2;
  final b = ByteData(44 + dataBytes);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little); // fmt chunk size
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  b.setUint16(32, 2, Endian.little); // block align
  b.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

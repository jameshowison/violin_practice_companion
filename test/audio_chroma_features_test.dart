import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_chroma_features.dart';
import 'package:wav/wav.dart';

Uint8List _sineWavBytes(double frequencyHz, double durationSeconds,
    {int sampleRate = 44100}) {
  final n = (durationSeconds * sampleRate).round();
  final samples = Float64List(n);
  for (var i = 0; i < n; i++) {
    samples[i] = 0.8 * math.sin(2 * math.pi * frequencyHz * i / sampleRate);
  }
  return Wav([samples], sampleRate).write();
}

/// A sum of `(frequencyHz, amplitude)` sinusoids.
Uint8List _mixedWavBytes(List<(double, double)> tones, double durationSeconds,
    {int sampleRate = 44100}) {
  final n = (durationSeconds * sampleRate).round();
  final samples = Float64List(n);
  for (var i = 0; i < n; i++) {
    var v = 0.0;
    for (final (hz, amp) in tones) {
      v += amp * math.sin(2 * math.pi * hz * i / sampleRate);
    }
    samples[i] = v;
  }
  return Wav([samples], sampleRate).write();
}

/// [halfSeconds] of [firstHz] followed by [halfSeconds] of [secondHz].
Uint8List _twoToneWavBytes(double firstHz, double secondHz, double halfSeconds,
    {int sampleRate = 44100}) {
  final half = (halfSeconds * sampleRate).round();
  final samples = Float64List(half * 2);
  for (var i = 0; i < half; i++) {
    samples[i] = 0.8 * math.sin(2 * math.pi * firstHz * i / sampleRate);
    samples[half + i] = 0.8 * math.sin(2 * math.pi * secondHz * i / sampleRate);
  }
  return Wav([samples], sampleRate).write();
}

void main() {
  group('AudioChromaExtractor', () {
    // The frequency-to-pitch-class mapping is tested with
    // [AudioChromaExtractor.noiseSubtractionFactor] at 0. A tone sustained
    // across a whole recording IS that recording's stationary spectrum, so
    // the subtraction removes it — correctly, since a component present
    // identically in every frame tells an alignment nothing about where in
    // the recording it is. Real material never looks like this; the
    // 'a note present in only part of a recording survives' test below
    // covers what subtraction does to actual note content.
    const mapping = AudioChromaExtractor(noiseSubtractionFactor: 0);

    test('a pure 440 Hz tone (A4) peaks in pitch class 9 (A)', () {
      final bytes = _sineWavBytes(440, 2.0);
      final chroma = mapping.extractFromWavBytes(bytes);

      expect(chroma.frames, isNotEmpty);
      // Skip the first/last frame: STFT edge frames straddle silence-padding.
      final steadyState = chroma.frames.sublist(2, chroma.frames.length - 2);
      for (final frame in steadyState) {
        final peakBin = _argmax(frame);
        expect(peakBin, 9, reason: 'frame should peak at A (pitch class 9)');
      }
    });

    test('a pure 261.63 Hz tone (C4) peaks in pitch class 0 (C)', () {
      final bytes = _sineWavBytes(261.63, 2.0);
      final chroma = mapping.extractFromWavBytes(bytes);

      final steadyState = chroma.frames.sublist(2, chroma.frames.length - 2);
      for (final frame in steadyState) {
        expect(_argmax(frame), 0, reason: 'frame should peak at C (pitch class 0)');
      }
    });

    test('a note present in only part of a recording survives noise '
        'subtraction', () {
      // Two seconds of A4 followed by two of D5 — the shape real material
      // has, and the case the subtraction must not damage: each tone is
      // absent for half the frames, so neither is in the stationary profile.
      final bytes = _twoToneWavBytes(440, 587.33, 2.0);
      final chroma = const AudioChromaExtractor().extractFromWavBytes(bytes);
      final hop = chroma.hopSeconds;

      int peakAt(double seconds) =>
          _argmax(chroma.frames[(seconds / hop).round()]);
      expect(peakAt(1.0), 9, reason: 'first half should peak at A');
      expect(peakAt(3.0), 2, reason: 'second half should peak at D');
    });

    test('a loud low-frequency hum cannot outvote a much quieter note', () {
      // 86 Hz is the loudest stationary bin in the Galopede teacher demo,
      // whose hum holds 81% of the recording's energy. It is below every note
      // a violin or mandolin can play (G3, 196 Hz), so the band must exclude
      // it: here it is 20x the amplitude of the A4 it is drowning, and A
      // (pitch class 9) must still win. The old 80 Hz band floor folded it
      // straight into the chroma, which is what made every frame of that
      // recording look alike.
      final bytes = _mixedWavBytes(
          const [(86.0, 0.8), (440.0, 0.04)], 2.0);
      final chroma = const AudioChromaExtractor(noiseSubtractionFactor: 0)
          .extractFromWavBytes(bytes);
      final steadyState = chroma.frames.sublist(2, chroma.frames.length - 2);
      for (final frame in steadyState) {
        expect(_argmax(frame), 9,
            reason: 'the note, not the hum, must decide the pitch class');
      }
    });

    test('hop duration matches hopSize / sampleRate', () {
      final bytes = _sineWavBytes(440, 1.0, sampleRate: 44100);
      const extractor = AudioChromaExtractor(hopSize: 1024);
      final chroma = extractor.extractFromWavBytes(bytes);
      expect(chroma.hopSeconds, closeTo(1024 / 44100, 1e-9));
    });

    test('every frame is L2-normalized (or all-zero for pure silence)', () {
      final bytes = _sineWavBytes(440, 0.5);
      final chroma = const AudioChromaExtractor().extractFromWavBytes(bytes);
      for (final frame in chroma.frames) {
        var sumSq = 0.0;
        for (final v in frame) {
          sumSq += v * v;
        }
        expect(math.sqrt(sumSq), anyOf(closeTo(0, 1e-9), closeTo(1, 1e-6)));
      }
    });
  });
}

int _argmax(Float64List v) {
  var best = 0;
  for (var i = 1; i < v.length; i++) {
    if (v[i] > v[best]) best = i;
  }
  return best;
}

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

void main() {
  group('AudioChromaExtractor', () {
    test('a pure 440 Hz tone (A4) peaks in pitch class 9 (A)', () {
      final bytes = _sineWavBytes(440, 2.0);
      final chroma = const AudioChromaExtractor().extractFromWavBytes(bytes);

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
      final chroma = const AudioChromaExtractor().extractFromWavBytes(bytes);

      final steadyState = chroma.frames.sublist(2, chroma.frames.length - 2);
      for (final frame in steadyState) {
        expect(_argmax(frame), 0, reason: 'frame should peak at C (pitch class 0)');
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

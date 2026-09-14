import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';
import 'package:wav/wav.dart';

import 'chroma_vector.dart';

/// A sequence of 12-bin chroma vectors (pitch-class energy over time, each
/// frame L2-normalized) extracted from real audio, used as one side of the
/// DTW alignment against [ScoreChromaReference] (see score_chroma_reference.dart).
class ChromaSequence {
  final List<Float64List> frames;
  final double hopSeconds;

  const ChromaSequence(this.frames, this.hopSeconds);

  double get durationSeconds => frames.length * hopSeconds;
}

/// Extracts a chroma feature sequence from real, sampled audio via a
/// windowed STFT (pure Dart, via `package:fftea`), folding FFT magnitude
/// bins into 12 pitch classes by an A440-referenced log-frequency mapping.
///
/// Input must be WAV (decoded via `package:wav`, also pure Dart) — there is
/// no reliable pure-Dart mp3 decoder, so tracks used for alignment are
/// shipped/converted to WAV. See docs/plan note in the audio-score-auto-align
/// branch history for why this was chosen over per-platform native decoders.
class AudioChromaExtractor {
  final int fftSize;
  final int hopSize;
  final double minFrequencyHz;
  final double maxFrequencyHz;

  const AudioChromaExtractor({
    this.fftSize = 4096,
    this.hopSize = 1024,
    this.minFrequencyHz = 80,
    this.maxFrequencyHz = 5000,
  });

  /// Decodes a whole WAV file's bytes and extracts its chroma sequence.
  ChromaSequence extractFromWavBytes(Uint8List wavBytes) {
    final wav = Wav.read(wavBytes);
    final mono = wav.toMono();
    return extractFromSamples(mono, wav.samplesPerSecond.toDouble());
  }

  /// Extracts chroma directly from mono PCM samples in `[-1, 1]`.
  ChromaSequence extractFromSamples(Float64List samples, double sampleRate) {
    final window = Window.hanning(fftSize);
    final stft = STFT(fftSize, window);
    final frames = <Float64List>[];

    stft.run(samples, (chunk) {
      final magnitudes = chunk.discardConjugates().magnitudes();
      frames.add(_toChroma(magnitudes, sampleRate));
    }, hopSize);

    return ChromaSequence(frames, hopSize / sampleRate);
  }

  Float64List _toChroma(Float64List magnitudes, double sampleRate) {
    final chroma = Float64List(kChromaBins);
    final binHz = sampleRate / fftSize;
    final minBin = (minFrequencyHz / binHz).ceil().clamp(1, magnitudes.length - 1);
    final maxBin = (maxFrequencyHz / binHz).floor().clamp(1, magnitudes.length - 1);
    for (var bin = minBin; bin <= maxBin; bin++) {
      chroma[_pitchClassOf(bin * binHz)] += magnitudes[bin];
    }
    l2NormalizeInPlace(chroma);
    return chroma;
  }

  /// Maps a frequency to a pitch class (C=0 .. B=11), A440-referenced:
  /// `12 * log2(f / 440)` is the signed semitone distance from A4, whose
  /// pitch class is 9 in this C=0 numbering.
  static int _pitchClassOf(double frequencyHz) {
    final semitonesFromA4 = 12 * (math.log(frequencyHz / 440.0) / math.ln2);
    final pitchClass = (semitonesFromA4.round() + 9) % 12;
    return pitchClass < 0 ? pitchClass + 12 : pitchClass;
  }
}

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
///
/// Two deliberate choices keep a real, imperfect room recording usable; see
/// docs/audio-sync-dtw-interior-gaps.md for the measurements behind both.
/// Folding *raw* magnitudes from 80 Hz up, as this once did, meant a quiet
/// recording's own noise floor decided its chroma: the Galopede teacher demo
/// carries a low hum whose loudest bins are 54-205 Hz and holds 81% of the
/// recording's energy below 200 Hz, so every frame's chroma was a re-binning
/// of that hum and near-identical to every other frame's. The alignment that
/// came out put its first anchor 19s after the first note.
class AudioChromaExtractor {
  final int fftSize;
  final int hopSize;

  /// Band folded into chroma. The default lower edge is just under G3
  /// (196 Hz), the lowest note on both violin and mandolin, so no real
  /// fundamental is excluded — but mains hum and handling rumble, which live
  /// below it, are. The upper edge sits above E7 (2637 Hz); higher partials
  /// contribute mostly bow/pick noise and broadband room tone.
  final double minFrequencyHz;
  final double maxFrequencyHz;

  /// Multiple of the recording's own stationary-noise profile subtracted from
  /// each frame's magnitudes before folding (0 disables). A constant hum sits
  /// at nearly the same level in every frame, so a low per-bin percentile
  /// over the whole recording estimates it well, while a played note is
  /// present in a minority of frames and survives. Over-subtracting a little
  /// is deliberate — it costs some of a real note's quietest partials to stop
  /// the noise floor from being normalized up to unit length and competing
  /// with them.
  ///
  /// It does not silence non-music frames outright: on the Galopede demo
  /// every one of the 2326 frames still has something above the floor after
  /// subtraction, because the hum's own frame-to-frame variance exceeds this
  /// margin. What it does is stop those frames from *resembling the score*,
  /// which is what the alignment actually depends on.
  final double noiseSubtractionFactor;

  /// Percentile (0-1) of each bin's magnitude over time taken as that bin's
  /// stationary-noise level.
  final double noisePercentile;

  const AudioChromaExtractor({
    this.fftSize = 4096,
    this.hopSize = 1024,
    this.minFrequencyHz = 180,
    this.maxFrequencyHz = 2600,
    this.noiseSubtractionFactor = 1.5,
    this.noisePercentile = 0.10,
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
    final binHz = sampleRate / fftSize;
    final noise = noiseSubtractionFactor > 0
        ? _noiseProfile(samples, window)
        : null;

    final frames = <Float64List>[];
    STFT(fftSize, window).run(samples, (chunk) {
      final magnitudes = chunk.discardConjugates().magnitudes();
      frames.add(_toChroma(magnitudes, binHz, noise));
    }, hopSize);

    return ChromaSequence(frames, hopSize / sampleRate);
  }

  /// Frames sampled for the noise profile. A stationary profile doesn't need
  /// every frame, and capping the count keeps this bounded for a long
  /// recording — the exact percentile over a few hundred evenly-spaced frames
  /// is as good an estimate of a constant hum as the percentile over all of
  /// them.
  static const int _noiseProfileFrames = 400;

  /// Per-bin [noisePercentile] magnitude over a decimated pass of the whole
  /// recording. Costs a second STFT pass rather than retaining every frame's
  /// spectrum, which for a few minutes of audio would run to tens of MB.
  Float64List? _noiseProfile(Float64List samples, Float64List window) {
    final totalFrames = (samples.length - fftSize) ~/ hopSize + 1;
    if (totalFrames < 2) return null;
    final stride = (totalFrames / _noiseProfileFrames).ceil();

    final sampled = <Float64List>[];
    var index = 0;
    STFT(fftSize, window).run(samples, (chunk) {
      if (index % stride == 0) {
        sampled.add(Float64List.fromList(chunk.discardConjugates().magnitudes()));
      }
      index++;
    }, hopSize);
    if (sampled.length < 2) return null;

    final binCount = sampled.first.length;
    final profile = Float64List(binCount);
    final column = Float64List(sampled.length);
    final rank = (sampled.length * noisePercentile).floor().clamp(0, sampled.length - 1);
    for (var bin = 0; bin < binCount; bin++) {
      for (var f = 0; f < sampled.length; f++) {
        column[f] = sampled[f][bin];
      }
      final sorted = Float64List.fromList(column)..sort();
      profile[bin] = sorted[rank];
    }
    return profile;
  }

  Float64List _toChroma(
      Float64List magnitudes, double binHz, Float64List? noise) {
    final chroma = Float64List(kChromaBins);
    final minBin = (minFrequencyHz / binHz).ceil().clamp(1, magnitudes.length - 1);
    final maxBin = (maxFrequencyHz / binHz).floor().clamp(1, magnitudes.length - 1);
    for (var bin = minBin; bin <= maxBin; bin++) {
      var magnitude = magnitudes[bin];
      if (noise != null && bin < noise.length) {
        magnitude -= noiseSubtractionFactor * noise[bin];
        if (magnitude <= 0) continue;
      }
      chroma[_pitchClassOf(bin * binHz)] += magnitude;
    }
    // Leaves an all-zero vector for a frame with nothing above the noise
    // floor, rather than normalizing noise up to unit length — see
    // [noiseSubtractionFactor].
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

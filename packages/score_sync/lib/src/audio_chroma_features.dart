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

  /// Per-frame attack strength in `[0, 1]`, one per [frames] entry: how
  /// suddenly the sound got louder there (see
  /// [AudioChromaExtractor.extractFromSamples]). Null when not measured.
  final Float64List? onsets;

  const ChromaSequence(this.frames, this.hopSeconds, {this.onsets});

  double get durationSeconds => frames.length * hopSeconds;
}

/// Extracts a chroma feature sequence from real, sampled audio via a
/// windowed STFT (pure Dart, via `package:fftea`), folding FFT magnitude
/// bins into 12 pitch classes by an A440-referenced log-frequency mapping.
///
/// Input is mono PCM ([extractFromSamples]): WAV bytes are decoded here via
/// `package:wav` ([extractFromWavBytes]); anything else is decoded first by
/// the per-platform `AudioDecoder` (audio_decoder.dart), which is how the
/// bundled tracks' `melody.mp3` and imported media are aligned.
///
/// Two deliberate choices keep a real, imperfect room recording usable; see
/// docs/audio-sync-dtw-interior-gaps.md for the measurements behind both.
/// Folding *raw* magnitudes from 80 Hz up, as this once did, meant a quiet
/// recording's own noise floor decided its chroma: the Galopede teacher demo
/// carries a low hum whose loudest bins are 54-205 Hz, and 81% of the
/// recording's energy lies below 200 Hz, so every frame's chroma was a re-binning
/// of that hum and near-identical to every other frame's. The alignment that
/// came out put its first anchor 19s after the first note.
class AudioChromaExtractor {
  /// STFT window and hop, in samples AT [referenceSampleRate]. Audio at any
  /// other rate is analysed with both scaled to the same durations (see
  /// [hopSizeFor]), so a frame is ~23 ms whatever the file's rate.
  ///
  /// Before, they were fixed sample counts, so a 22.05 kHz file got frames
  /// twice as long as a 44.1 kHz one, and every frame-counted constant
  /// downstream — the DTW skip and step penalties, the refinement windows —
  /// meant something different per file. The attack term tuned on a 22 kHz
  /// conversion and broken on the iPad's native 44.1 kHz decode (bec1079)
  /// was one instance; Android, whose decoders report 48 kHz for most AAC,
  /// would have been the next.
  final int fftSize;
  final int hopSize;

  /// The rate [fftSize] and [hopSize] are stated at. 44.1 kHz because it is
  /// what every alignment fixture and most imported files are, so their
  /// analysis is bit-for-bit what it was before the scaling existed.
  static const double referenceSampleRate = 44100;

  /// [hopSize] scaled to [sampleRate].
  int hopSizeFor(double sampleRate) =>
      math.max(1, (hopSize * sampleRate / referenceSampleRate).round());

  /// [fftSize] scaled to [sampleRate], rounded to the nearest power of two
  /// (the FFT's fast path): 2048 at 22.05 kHz, 4096 at 44.1 and 48 kHz. The
  /// window's length in time only sets frequency resolution, which stays
  /// within 10% of the reference; the hop, which sets frame timing, is exact.
  int fftSizeFor(double sampleRate) {
    final target = fftSize * sampleRate / referenceSampleRate;
    final exponent = (math.log(math.max(target, 16)) / math.ln2).round();
    return 1 << exponent;
  }

  /// Band folded into chroma. The default lower edge is just under G3
  /// (196 Hz), the lowest note on both violin and mandolin, so no real
  /// fundamental is excluded — but mains hum and handling rumble, which live
  /// below it, are. The upper edge sits just under E7 (2637 Hz); higher partials
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
    this.silenceGate = 0.001,
  });

  /// Frames whose in-band energy is below this fraction of the recording's
  /// 95th-percentile frame energy (0.001 is 30 dB down) become all-zero:
  /// silence, which matches no note (0 disables).
  ///
  /// Noise subtraction alone leaves something in a quiet frame, and
  /// normalizing makes it unit length, so a decaying open string reads as a
  /// full-strength note. On a teacher video that rang its last D for four
  /// seconds after the final bar, the closing bars of repeated Ds spread over
  /// that ring and every bar from the last rests on landed 1-2 s late. Gated,
  /// the ring is silence, and the open end skips it.
  final double silenceGate;

  /// Decodes a whole WAV file's bytes and extracts its chroma sequence.
  ChromaSequence extractFromWavBytes(Uint8List wavBytes) {
    final wav = Wav.read(wavBytes);
    final mono = wav.toMono();
    return extractFromSamples(mono, wav.samplesPerSecond.toDouble());
  }

  /// Extracts chroma directly from mono PCM samples in `[-1, 1]`.
  ChromaSequence extractFromSamples(Float64List samples, double sampleRate) {
    final fftSize = fftSizeFor(sampleRate);
    final hopSize = hopSizeFor(sampleRate);
    final window = Window.hanning(fftSize);
    final binHz = sampleRate / fftSize;
    final noise = noiseSubtractionFactor > 0
        ? _noiseProfile(samples, window, fftSize, hopSize)
        : null;

    final frames = <Float64List>[];
    final energies = <double>[];
    final flux = <double>[];
    Float64List? previous;
    STFT(fftSize, window).run(samples, (chunk) {
      final magnitudes = chunk.discardConjugates().magnitudes();
      frames.add(_toChroma(magnitudes, binHz, noise));
      if (silenceGate > 0) energies.add(_bandEnergy(magnitudes, binHz));
      final logMagnitudes = _bandLogMagnitudes(magnitudes, binHz);
      flux.add(previous == null ? 0 : _flux(previous!, logMagnitudes));
      previous = logMagnitudes;
    }, hopSize);
    if (silenceGate > 0 && energies.isNotEmpty) {
      final sorted = [...energies]..sort();
      final loud = sorted[((sorted.length - 1) * 0.95).round()];
      for (var f = 0; f < frames.length; f++) {
        if (energies[f] < silenceGate * loud) {
          frames[f].fillRange(0, kChromaBins, 0);
        }
      }
    }

    final onsets = _onsetStrength(flux);
    // A gated frame is silence: nothing is attacked in it either.
    for (var f = 0; f < frames.length; f++) {
      if (!frames[f].any((x) => x > 0)) onsets[f] = 0;
    }
    return ChromaSequence(frames, hopSize / sampleRate, onsets: onsets);
  }

  /// [flux] rescaled to `[0, 1]`: 0 at or below its median (the steady
  /// bow-and-room level every frame has), 1 at or above its 98th percentile
  /// (a clear attack).
  static Float64List _onsetStrength(List<double> flux) {
    final out = Float64List(flux.length);
    if (flux.length < 2) return out;
    final sorted = [...flux]..sort();
    final floor = sorted[sorted.length ~/ 2];
    final peak = sorted[((sorted.length - 1) * 0.98).round()];
    if (peak <= floor) return out;
    for (var f = 0; f < flux.length; f++) {
      out[f] = ((flux[f] - floor) / (peak - floor)).clamp(0.0, 1.0);
    }
    return out;
  }

  /// Log magnitudes of the folded band, for [_flux].
  Float64List _bandLogMagnitudes(Float64List magnitudes, double binHz) {
    final minBin =
        (minFrequencyHz / binHz).ceil().clamp(1, magnitudes.length - 1);
    final maxBin =
        (maxFrequencyHz / binHz).floor().clamp(1, magnitudes.length - 1);
    final out = Float64List(maxBin - minBin + 1);
    for (var bin = minBin; bin <= maxBin; bin++) {
      out[bin - minBin] = math.log(1 + magnitudes[bin]);
    }
    return out;
  }

  /// Spectral flux: the summed rise in log magnitude from one frame to the
  /// next. A new bow stroke on the same note shows here even though the
  /// chroma doesn't change at all.
  static double _flux(Float64List previous, Float64List current) {
    var sum = 0.0;
    for (var k = 0; k < current.length; k++) {
      final rise = current[k] - previous[k];
      if (rise > 0) sum += rise;
    }
    return sum;
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
  Float64List? _noiseProfile(
      Float64List samples, Float64List window, int fftSize, int hopSize) {
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

  /// A frame's energy within the folded band, before noise subtraction.
  double _bandEnergy(Float64List magnitudes, double binHz) {
    final minBin =
        (minFrequencyHz / binHz).ceil().clamp(1, magnitudes.length - 1);
    final maxBin =
        (maxFrequencyHz / binHz).floor().clamp(1, magnitudes.length - 1);
    var e = 0.0;
    for (var bin = minBin; bin <= maxBin; bin++) {
      e += magnitudes[bin] * magnitudes[bin];
    }
    return e;
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

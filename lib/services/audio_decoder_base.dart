import 'dart:typed_data';

/// Mono PCM in `[-1, 1]` plus the rate it was sampled at — the one form
/// [AudioChromaExtractor.extractFromSamples] consumes, and therefore the only
/// thing a decoder has to produce.
class PcmAudio {
  final Float64List samples;
  final double sampleRate;

  const PcmAudio(this.samples, this.sampleRate);

  double get durationSeconds =>
      sampleRate <= 0 ? 0 : samples.length / sampleRate;
}

/// Decodes a compressed audio or video file to mono PCM so it can be aligned
/// to the score.
///
/// Before this existed the app could analyse WAV and nothing else — there is
/// no reliable pure-Dart mp3 decoder, so `audio_chroma_features.dart` decoded
/// WAV via `package:wav` and every alignable medium had to BE a WAV. That is
/// why bundled folders ship a `melody.wav` next to their mp3s, and why the
/// teacher-demo capture records a silent video and a separate WAV rather than
/// one ordinary movie file.
///
/// That constraint is invisible as long as the app supplies all the audio
/// itself. It stops being invisible the moment a user picks an m4a off their
/// phone: the file plays perfectly through `just_audio` and cannot be aligned
/// at all, so the same action produces a working medium or a half-working one
/// depending on a container format nobody chose. Hence a real decoder, per
/// platform, behind this interface.
///
/// **Memory.** Decoding is whole-file: a five-minute 48 kHz recording is about
/// 57 MB of `Float64List`, plus the same again briefly while the platform's
/// `Float32List` is widened. That is acceptable for the recordings this app
/// deals with (a demo of one tune) and would not be for an album side. The
/// samples are dropped as soon as chroma extraction has run.
abstract class AudioDecoderBase {
  /// False where no decoder is wired up at all. Callers fall back to "this
  /// medium plays but cannot drive the highlight" rather than failing.
  bool get isSupported;

  /// Decodes the file at [absolutePath]. Returns null when the format is
  /// unreadable, the file is missing, or the platform declined — all of which
  /// mean the same thing to a caller, which is that this medium has no
  /// analysis source.
  ///
  /// Never throws for an ordinary decode failure. A thrown exception here
  /// would have to be caught at every call site and turned back into null.
  Future<PcmAudio?> decodeFile(String absolutePath);

  /// Decodes an in-memory file. [extension] (no dot, lowercased) tells the
  /// decoder what it is holding, since bytes alone don't say.
  Future<PcmAudio?> decodeBytes(Uint8List bytes, {required String extension});
}

/// Container/codec extensions worth offering in a file picker.
///
/// Video formats are here because a video file's audio track is what gets
/// aligned — an imported mp4 behaves exactly like a recorded demo, which is
/// the point of treating every medium the same way.
const List<String> importableAudioExtensions = [
  'wav',
  'mp3',
  'm4a',
  'aac',
  'aif',
  'aiff',
  'caf',
  'flac',
  'ogg',
];

const List<String> importableVideoExtensions = ['mp4', 'mov', 'm4v'];

bool isVideoExtension(String extension) =>
    importableVideoExtensions.contains(extension.toLowerCase());

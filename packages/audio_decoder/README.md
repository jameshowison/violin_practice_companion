# audio_decoder

Decodes an audio or video file to mono float PCM at the file's own sample
rate: the input that pitch, onset and chroma analysis want. It came out of
Stringlings, where it feeds the score-to-audio alignment
(`docs/family/libraries.md`, "5. audio_decoder").

- **`AudioDecoder`:** `decodeFile(path)` and `decodeBytes(bytes, extension:)`
  return a `PcmAudio` (`samples` as `Float64List` in `[-1, 1]`, and
  `sampleRate`), or null when the file can't be read. An ordinary decode
  failure never throws.
- **WAV** is read in Dart (`package:wav`), so it works under `flutter test`
  with no device.
- **Everything else** goes over the `audio_decoder` method channel
  (`decodeToPcm`) to the platform:
  - **iOS:** `AVAssetReader`, asked for 32-bit float mono at the track's
    own rate (`ios/Classes/AudioDecoderPlugin.swift`).
  - **Android:** `MediaExtractor` and `MediaCodec`, mixed to mono here
    (`android/src/main/kotlin/.../AudioDecoderPlugin.kt`). The sample rate
    and channel count are taken from the decoder's output format, not the
    container: HE-AAC (SBR) is signalled at half its rate, and trusting the
    container would stretch every timing by 2x.
- **`importableAudioExtensions`, `importableVideoExtensions`,
  `isVideoExtension`:** what a file picker should offer.

The rate matters more than anything else here: a wrong rate scales every
time derived from the samples, and the result looks plausible rather than
broken. Check a decode by the span of what it times, not by the absence of
an error.

Decoding is whole-file: five minutes at 48 kHz is about 57 MB of samples.

iOS and Android only. Elsewhere `isSupported` is false and only WAV decodes.

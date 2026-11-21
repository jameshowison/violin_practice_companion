/// Decode an audio or video file to mono PCM at its own sample rate.
///
/// iOS and Android decode through the plugin (AVAssetReader / MediaCodec);
/// WAV is read in pure Dart. See `src/audio_decoder_io.dart`.
library;

export 'src/audio_decoder_base.dart';
export 'src/audio_decoder_io.dart';

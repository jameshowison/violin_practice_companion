// iOS/Android/macOS decode through a platform channel (AVAssetReader /
// MediaCodec); web uses the browser's own `decodeAudioData`. WAV is handled in
// pure Dart on both sides — see audio_decoder_io.dart.
export 'audio_decoder_base.dart';
export 'audio_decoder_io.dart'
    if (dart.library.html) 'audio_decoder_web.dart';

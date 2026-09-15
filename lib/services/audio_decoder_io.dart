import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wav/wav.dart';

import 'audio_decoder_base.dart';

/// Decodes through the host platform: `AVAssetReader` on iOS/macOS,
/// `MediaExtractor`+`MediaCodec` on Android (see
/// `ios/Runner/AudioDecoderPlugin.swift` and
/// `android/app/src/main/kotlin/.../AudioDecoderPlugin.kt`). Both hand back
/// mono `Float32` at the source sample rate; everything about what to do with
/// it lives here.
///
/// WAV never reaches the channel. `package:wav` already reads it in pure Dart,
/// which is faster than a platform round trip, works in `flutter test` with no
/// device, and keeps every existing alignment test running exactly as it did.
class AudioDecoder implements AudioDecoderBase {
  /// Matches the channel name registered in both native plugins.
  static const MethodChannel channel =
      MethodChannel('violin_practice_companion/audio_decoder');

  const AudioDecoder();

  /// Linux and Windows have no plugin; they still decode WAV, which is what
  /// every bundled analysis track is, so bundled Play Along keeps working
  /// there and only imported non-WAV media is affected.
  @override
  bool get isSupported => Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

  @override
  Future<PcmAudio?> decodeFile(String absolutePath) async {
    final extension = _extensionOf(absolutePath);
    if (extension == 'wav') {
      try {
        return _decodeWavBytes(await File(absolutePath).readAsBytes());
      } catch (e) {
        debugPrint('AudioDecoder: WAV decode failed for $absolutePath — $e');
        return null;
      }
    }
    if (!isSupported) return null;
    return _decodeViaPlatform(absolutePath);
  }

  @override
  Future<PcmAudio?> decodeBytes(Uint8List bytes,
      {required String extension}) async {
    if (extension == 'wav') {
      try {
        return _decodeWavBytes(bytes);
      } catch (e) {
        debugPrint('AudioDecoder: WAV decode failed — $e');
        return null;
      }
    }
    if (!isSupported) return null;
    // The native decoders read files, not buffers: both APIs want a URL, and
    // handing them one avoids copying the whole compressed file across the
    // channel only for the platform to need it on disk anyway. Asset-backed
    // media are the only callers, and in practice they are already WAV.
    final temporary = File('${(await getTemporaryDirectory()).path}/'
        'decode_${DateTime.now().microsecondsSinceEpoch}.$extension');
    try {
      await temporary.writeAsBytes(bytes);
      return await _decodeViaPlatform(temporary.path);
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // An undeleted temp file is cache noise the OS will reclaim.
      }
    }
  }

  Future<PcmAudio?> _decodeViaPlatform(String absolutePath) async {
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'decodeToPcm',
        {'path': absolutePath},
      );
      if (result == null) return null;
      final samples = result['samples'];
      final sampleRate = (result['sampleRate'] as num?)?.toDouble() ?? 0;
      if (samples is! Float32List || sampleRate <= 0) return null;
      if (samples.isEmpty) return null;
      // Widened here rather than natively: the channel moves half as many
      // bytes as Float64 would, and the extractor wants Float64.
      final widened = Float64List(samples.length);
      for (var i = 0; i < samples.length; i++) {
        widened[i] = samples[i];
      }
      return PcmAudio(widened, sampleRate);
    } on MissingPluginException {
      // The plugin isn't registered — an older build of the native side, or a
      // platform this was never wired up for. Same outcome as an unreadable
      // file: no analysis source.
      debugPrint('AudioDecoder: no native decoder registered on this platform.');
      return null;
    } on PlatformException catch (e) {
      debugPrint('AudioDecoder: native decode failed — ${e.code}: ${e.message}');
      return null;
    }
  }

  PcmAudio _decodeWavBytes(Uint8List bytes) {
    final wav = Wav.read(bytes);
    return PcmAudio(wav.toMono(), wav.samplesPerSecond.toDouble());
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf(Platform.pathSeparator);
    if (dot <= slash + 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }
}

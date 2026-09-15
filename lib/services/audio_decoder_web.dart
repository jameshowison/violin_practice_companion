import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:wav/wav.dart';
import 'package:web/web.dart' as web;

import 'audio_decoder_base.dart';

/// Decodes with the browser's own `AudioContext.decodeAudioData`, which
/// handles whatever the browser can play — mp3, m4a/aac, ogg, and the audio
/// track of an mp4.
///
/// There are no file-backed media on web (see media_paths_web.dart), so
/// [decodeFile] is unreachable and only [decodeBytes] does any work — which is
/// the right way round here anyway, since the Web Audio API takes an
/// `ArrayBuffer` and knows nothing about paths.
class AudioDecoder implements AudioDecoderBase {
  const AudioDecoder();

  @override
  bool get isSupported => true;

  @override
  Future<PcmAudio?> decodeFile(String absolutePath) async => null;

  @override
  Future<PcmAudio?> decodeBytes(Uint8List bytes,
      {required String extension}) async {
    // Same short-circuit as the io side: `package:wav` is already here, and
    // going through an AudioContext to read a WAV would spin up an audio
    // device for nothing.
    if (extension == 'wav') {
      try {
        final wav = Wav.read(bytes);
        return PcmAudio(wav.toMono(), wav.samplesPerSecond.toDouble());
      } catch (e) {
        debugPrint('AudioDecoder: WAV decode failed — $e');
        return null;
      }
    }

    web.AudioContext? context;
    try {
      context = web.AudioContext();
      // `decodeAudioData` detaches the buffer it is given, so it gets a copy —
      // the caller's bytes may well be the same `Uint8List` that is about to
      // be written to disk.
      final copy = Uint8List.fromList(bytes);
      final buffer =
          await context.decodeAudioData(copy.buffer.toJS).toDart;
      return _toMono(buffer);
    } catch (e) {
      debugPrint('AudioDecoder: browser decode failed — $e');
      return null;
    } finally {
      // An AudioContext is a real hardware handle and browsers cap how many a
      // page may hold, so it is closed whether or not the decode worked.
      try {
        context?.close();
      } catch (_) {
        // Already closed, or the browser took it away.
      }
    }
  }

  /// Averages the channels rather than taking the first: a recording with the
  /// instrument panned to one side would otherwise analyse as near-silence.
  PcmAudio _toMono(web.AudioBuffer buffer) {
    final frames = buffer.length;
    final channels = buffer.numberOfChannels;
    final mono = Float64List(frames);
    for (var c = 0; c < channels; c++) {
      final data = buffer.getChannelData(c).toDart;
      for (var i = 0; i < frames; i++) {
        mono[i] += data[i];
      }
    }
    if (channels > 1) {
      for (var i = 0; i < frames; i++) {
        mono[i] /= channels;
      }
    }
    return PcmAudio(mono, buffer.sampleRate.toDouble());
  }
}

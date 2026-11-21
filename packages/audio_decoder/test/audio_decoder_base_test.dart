import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pure half. The channel contract (Float32 widening, malformed replies,
/// WAV never reaching the platform) is pinned in the app's
/// test/audio_decoder_test.dart, next to the alignment it feeds.
void main() {
  group('PcmAudio', () {
    test('duration is samples over rate', () {
      final pcm = PcmAudio(Float64List(22050), 44100);
      expect(pcm.durationSeconds, 0.5);
    });

    test('a non-positive rate has no duration rather than a division error',
        () {
      expect(PcmAudio(Float64List(10), 0).durationSeconds, 0);
      expect(PcmAudio(Float64List(10), -1).durationSeconds, 0);
    });
  });

  group('extensions', () {
    test('video extensions are recognised in any case', () {
      expect(isVideoExtension('mp4'), isTrue);
      expect(isVideoExtension('MOV'), isTrue);
      expect(isVideoExtension('m4v'), isTrue);
      expect(isVideoExtension('m4a'), isFalse);
      expect(isVideoExtension('wav'), isFalse);
    });

    test('audio and video lists do not overlap', () {
      expect(
          importableAudioExtensions
              .where(importableVideoExtensions.contains),
          isEmpty);
    });
  });
}

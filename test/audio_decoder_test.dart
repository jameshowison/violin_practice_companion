import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_decoder.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Exercises the Dart half of the decoder — the contract with the native
/// plugins, and the WAV short-circuit that never reaches them.
///
/// The native decoders themselves (AVAssetReader on iOS, MediaCodec on
/// Android) cannot run here; what is pinned is the shape they must return and
/// what happens when they don't.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `assets/audio/` is gitignored, so the two tests that need real audio skip
  // when it isn't present — the same pattern as lightly_row_intro_align_test.
  final wavFile = File('assets/audio/lightly_row/melody.wav');
  final xmlFile = File('assets/fixtures/lightly_row_musescore.xml');
  final haveAudio = wavFile.existsSync() && xmlFile.existsSync();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockChannel(Future<Object?> Function(MethodCall call)? handler) {
    messenger.setMockMethodCallHandler(AudioDecoder.channel, handler);
  }

  tearDown(() => mockChannel(null));

  group('the native contract', () {
    test('widens the platform\'s Float32 samples to what the extractor wants',
        () async {
      late MethodCall received;
      mockChannel((call) async {
        received = call;
        return <String, Object?>{
          'sampleRate': 44100,
          'samples': Float32List.fromList([0.0, 0.5, -0.5, 1.0]),
        };
      });

      final pcm = await const AudioDecoder().decodeFile('/tmp/lesson.m4a');

      expect(received.method, 'decodeToPcm');
      expect(received.arguments, {'path': '/tmp/lesson.m4a'});
      expect(pcm, isNotNull);
      expect(pcm!.sampleRate, 44100.0);
      expect(pcm.samples, isA<Float64List>());
      expect(pcm.samples.toList(), [0.0, 0.5, -0.5, 1.0]);
      expect(pcm.durationSeconds, closeTo(4 / 44100, 1e-9));
    });

    test('a decode failure is null, not a throw', () async {
      // Callers turn this into "plays, but the score won't follow" — an
      // outcome, not an error path. A throw here would have to be caught at
      // every call site and turned back into null.
      mockChannel((call) async =>
          throw PlatformException(code: 'decode_failed', message: 'no audio track'));

      expect(await const AudioDecoder().decodeFile('/tmp/silent.mp4'), isNull);
    });

    test('an unregistered plugin is null, not a throw', () async {
      mockChannel(null); // MissingPluginException
      expect(await const AudioDecoder().decodeFile('/tmp/lesson.m4a'), isNull);
    });

    test('a malformed reply is rejected rather than half-trusted', () async {
      for (final reply in <Map<String, Object?>>[
        {'sampleRate': 44100}, // no samples
        {'samples': Float32List.fromList([0.1])}, // no rate
        {'sampleRate': 0, 'samples': Float32List.fromList([0.1])},
        {'sampleRate': 44100, 'samples': Float32List(0)},
        {'sampleRate': 44100, 'samples': 'not samples'},
      ]) {
        mockChannel((call) async => reply);
        expect(await const AudioDecoder().decodeFile('/tmp/x.m4a'), isNull,
            reason: 'reply $reply should not produce audio');
      }
    });
  });

  group('WAV never reaches the platform', () {
    test('decodes in pure Dart, leaving the channel untouched', () async {
      var channelCalled = false;
      mockChannel((call) async {
        channelCalled = true;
        return null;
      });

      final pcm = await const AudioDecoder()
          .decodeBytes(wavFile.readAsBytesSync(), extension: 'wav');

      expect(channelCalled, isFalse,
          reason: 'a platform round trip for WAV would be pure overhead, and '
              'would take every alignment test off-device');
      expect(pcm, isNotNull);
      expect(pcm!.sampleRate, greaterThan(0));
      expect(pcm.samples, isNotEmpty);
    }, skip: haveAudio ? null : 'assets/audio not present');

    test('a corrupt WAV is null, not a throw', () async {
      final pcm = await const AudioDecoder()
          .decodeBytes(Uint8List.fromList([1, 2, 3, 4]), extension: 'wav');
      expect(pcm, isNull);
    });
  });

  test('decoded PCM aligns to a score exactly as WAV bytes do', () async {
    // The seam that makes an imported mp3 a first-class medium: whatever the
    // decoder produces goes through the same aligner as a bundled WAV, so the
    // two entry points must agree.
    final bytes = wavFile.readAsBytesSync();
    final piece = MusicXmlParser().parse(xmlFile.readAsStringSync());

    final decoded =
        await const AudioDecoder().decodeBytes(bytes, extension: 'wav');
    final aligner =
        AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest());

    final fromWav = aligner.align(piece, bytes);
    final fromPcm = aligner.alignPcm(piece, decoded!);

    expect(fromPcm.generationBpm, fromWav.generationBpm);
    expect(fromPcm.anchors.length, fromWav.anchors.length);
    for (var i = 0; i < fromWav.anchors.length; i++) {
      expect(fromPcm.anchors[i].audioSec, fromWav.anchors[i].audioSec);
      expect(fromPcm.anchors[i].scoreMs, fromWav.anchors[i].scoreMs);
    }
  }, skip: haveAudio ? null : 'assets/audio not present');
}

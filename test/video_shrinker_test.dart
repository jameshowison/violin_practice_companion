import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:violin_practice_companion/services/piece_media_store.dart';
import 'package:violin_practice_companion/services/video_shrinker_io.dart';

void main() {
  late Directory docs;
  late PieceMediaStore store;
  late int nativeCalls;

  Future<String> resolve(String relative) async => '${docs.path}/$relative';

  /// Writes [bytes] at [destination], as the native encoder would.
  NativeVideoShrink writes(int bytes) => (source, destination) async {
        nativeCalls++;
        await File(destination).writeAsBytes(List.filled(bytes, 0));
        return {'width': 1280, 'height': 720, 'codec': 'hevc', 'bytes': bytes};
      };

  VideoShrinker shrinker(NativeVideoShrink native) =>
      VideoShrinker(store: store, nativeShrink: native, resolve: resolve);

  const original = MediaRef.appFile('media/p1/import_1/source.mov');
  const shrunk = MediaRef.appFile('media/p1/import_1/video_720.mp4');
  const imported = PieceMedia(
    id: 'import_1',
    label: 'Teacher video',
    kind: MediaKind.imported,
    alignmentKey: 'media:p1:import_1',
    audio: original,
    analysis: original,
    video: original,
    avOffsetMs: 0,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('video_shrinker_test');
    await Directory('${docs.path}/media/p1/import_1').create(recursive: true);
    await File(await resolve(original.path)).writeAsBytes(List.filled(1000, 1));
    store = PieceMediaStore();
    await store.add('p1', imported);
    nativeCalls = 0;
  });

  tearDown(() => docs.delete(recursive: true));

  Future<PieceMedia> stored() async => (await store.load('p1')).single;
  Future<bool> exists(MediaRef ref) async => File(await resolve(ref.path)).exists();

  test('the swap waits for launch, and the original for the launch after', () async {
    final s = shrinker(writes(200));
    await s.shrinkNow('p1', imported);
    // Mid-session nothing moves: the transport may be playing the original.
    expect((await stored()).video, original);
    expect(await exists(shrunk), isTrue);

    await s.applyFinishedShrinks(); // next launch
    final media = await stored();
    expect(media.audio, shrunk);
    expect(media.analysis, shrunk);
    expect(media.video, shrunk);
    expect(media.alignmentKey, imported.alignmentKey,
        reason: 'same audio, so the cached alignment still holds');
    expect(await exists(original), isTrue,
        reason: 'a session that read the list before the swap may hold it');

    await s.applyFinishedShrinks(); // the launch after
    expect(await exists(original), isFalse);
    expect(await exists(shrunk), isTrue);
  });

  test('a skipped video is not offered to the encoder again', () async {
    final s = shrinker((source, destination) async {
      nativeCalls++;
      return {'skipped': 'already small'};
    });
    await s.shrinkNow('p1', imported);
    await s.shrinkNow('p1', imported);
    expect(nativeCalls, 1);
    await s.applyFinishedShrinks();
    expect((await stored()).video, original);
  });

  test('a failing video is retried, but not forever', () async {
    final s = shrinker((source, destination) async {
      nativeCalls++;
      throw PlatformException(code: 'shrink_failed');
    });
    for (var i = 0; i < VideoShrinker.maxAttempts + 2; i++) {
      await s.shrinkNow('p1', imported);
    }
    expect(nativeCalls, VideoShrinker.maxAttempts);
  });

  test('a copy that is no smaller is thrown away', () async {
    final s = shrinker(writes(5000));
    await s.shrinkNow('p1', imported);
    expect(await exists(shrunk), isFalse);
    await s.applyFinishedShrinks();
    expect((await stored()).video, original);
  });

  test('a medium deleted before the swap leaves no orphan behind', () async {
    final s = shrinker(writes(200));
    await s.shrinkNow('p1', imported);
    await store.remove('p1', imported.id);
    await s.applyFinishedShrinks();
    expect(await exists(shrunk), isFalse);
  });

  test('a recorded demo swaps only its video', () {
    const wav = MediaRef.appFile('media/p1/demo/audio.wav');
    const mov = MediaRef.appFile('media/p1/demo/video.mov');
    const mp4 = MediaRef.appFile('media/p1/demo/video_720.mp4');
    const demo = PieceMedia(
      id: 'demo',
      label: 'Demo',
      kind: MediaKind.recorded,
      alignmentKey: 'media:p1:demo',
      audio: wav,
      analysis: wav,
      video: mov,
      avOffsetMs: 120,
    );
    final swapped = demo.withFileReplaced(mov, mp4);
    expect(swapped.audio, wav);
    expect(swapped.analysis, wav);
    expect(swapped.video, mp4);
    expect(swapped.avOffsetMs, 120);
  });
}

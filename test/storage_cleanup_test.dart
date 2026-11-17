import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/services/storage_cleanup_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root, docs, tmp, cache;
  final now = DateTime(2026, 11, 17, 12);
  final old = now.subtract(const Duration(days: 3));
  final recent = now.subtract(const Duration(hours: 2));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('storage_cleanup');
    docs = await Directory('${root.path}/Documents').create();
    tmp = await Directory('${root.path}/tmp').create();
    cache = await Directory('${root.path}/Library/Caches').create(recursive: true);
    // path_provider's temporary directory is `cache` (Library/Caches on iOS).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => cache.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => root.delete(recursive: true));

  StorageCleanup cleanup({bool byPath = false}) => StorageCleanup(
      documents: docs,
      scratchDirectories: [tmp, cache],
      now: () => now,
      assetsLoadByPath: () async => byPath);

  File put(Directory dir, String rel, {DateTime? modified, int bytes = 10}) {
    final f = File('${dir.path}/$rel')..createSync(recursive: true);
    f.writeAsBytesSync(List.filled(bytes, 1));
    f.setLastModifiedSync(modified ?? old);
    return f;
  }

  test('deleteScratch removes picker, cropper and scanner copies only', () async {
    final picked = put(tmp, 'Trepak practice video.mov');
    final cropped = put(tmp, 'image_cropper_ABC.png');
    final scanned = put(docs, '20261110-073532-0.png');
    final userDoc = put(docs, 'notes.png'); // not a scanner name
    final elsewhere = put(root, 'Shared/teacher.mov'); // picked in place
    final c = cleanup();
    for (final f in [picked, cropped, scanned, userDoc, elsewhere]) {
      await c.deleteScratch(f.path);
    }
    expect(picked.existsSync(), isFalse);
    expect(cropped.existsSync(), isFalse);
    expect(scanned.existsSync(), isFalse);
    expect(userDoc.existsSync(), isTrue);
    expect(elsewhere.existsSync(), isTrue);
  });

  test('sweep clears old scratch but not the caches that live beside it',
      () async {
    final oldPick = put(tmp, 'Trepak.mov', bytes: 1000);
    final newPick = put(tmp, 'just_picked.mov', modified: recent);
    final omrPage = put(cache, 'omr_page_1794346767931_0.png');
    final model = put(cache, 'decoder_fp16.onnx');
    final soundfont = put(cache, 'generaluser_gs.sf2');
    final engraved = put(cache, 'engrave/abc.svg');
    final pickerCache = put(cache, 'file_picker/1234/score.pdf');
    final scanner = put(docs, '20261115-161017-1.png');

    final freed = await cleanup().sweep();
    expect(oldPick.existsSync(), isFalse);
    expect(omrPage.existsSync(), isFalse);
    expect(pickerCache.existsSync(), isFalse);
    expect(scanner.existsSync(), isFalse);
    expect(newPick.existsSync(), isTrue, reason: 'may still be mid-import');
    expect(model.existsSync(), isTrue);
    expect(soundfont.existsSync(), isTrue);
    expect(engraved.existsSync(), isTrue);
    expect(freed, greaterThanOrEqualTo(1000));
  });

  group('unreferenced media', () {
    const row = '[{"id":"m1","audio":{"storage":"appFile",'
        '"path":"media/p/m1/video_720.mp4"}}]';

    test('a file no preference names is removed; named and new ones stay',
        () async {
      SharedPreferences.setMockInitialValues({
        'pieceMedia.p': row,
        // A legacy recording, stored absolute and not yet migrated.
        'teacherRecording.q':
            '{"audioPath":"/var/old-container/Documents/teacher_recordings/q/audio.wav"}',
        'videoShrink.retired': ['media/p/m1/source.mov'],
      });
      final named = put(docs, 'media/p/m1/video_720.mp4');
      final legacy = put(docs, 'teacher_recordings/q/audio.wav');
      final retired = put(docs, 'media/p/m1/source.mov');
      final stray = put(docs, 'teacher_recordings/We+Wish practice video.mp4');
      final fresh = put(docs, 'media/p/m2/source.mp4', modified: recent);

      await cleanup().sweep();
      expect(named.existsSync(), isTrue);
      expect(legacy.existsSync(), isTrue);
      expect(retired.existsSync(), isTrue,
          reason: 'the shrinker deletes it itself, a launch later');
      expect(fresh.existsSync(), isTrue, reason: 'an import still in flight');
      expect(stray.existsSync(), isFalse);
    });

    test("the dev-library sync's file record doesn't keep an orphan alive",
        () async {
      SharedPreferences.setMockInitialValues({
        'pieceMedia.p': row,
        'devLibrary.base':
            '{"file:teacher_recordings/We+Wish practice video.mp4":"123:456"}',
      });
      final stray = put(docs, 'teacher_recordings/We+Wish practice video.mp4');
      await cleanup().sweep();
      expect(stray.existsSync(), isFalse);
    });

    test('with no media rows at all, nothing is touched', () async {
      // What a device whose preferences were lost looks like.
      final file = put(docs, 'media/p/m1/source.mov');
      await cleanup().sweep();
      expect(file.existsSync(), isTrue);
    });
  });

  test('sweep removes the plugins\' old asset copies only once assets load '
      'by path', () async {
    final sf = put(cache, 'generaluser_gs.sf2', modified: recent, bytes: 100);
    final other = put(cache, 'other.sf2', modified: old);
    await cleanup().sweep();
    expect(sf.existsSync(), isTrue, reason: 'still the live copy (macOS)');
    await cleanup(byPath: true).sweep();
    expect(sf.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/media_paths_io.dart';

void main() {
  late Directory docs;

  setUp(() => docs = Directory.systemTemp.createTempSync('media_folder_'));
  tearDown(() => docs.deleteSync(recursive: true));

  File touch(String rel) =>
      File('${docs.path}/$rel')..createSync(recursive: true);

  test('removes the piece folder, empty or not, and leaves its siblings',
      () async {
    Directory('${docs.path}/media/gone/teacher_1').createSync(recursive: true);
    touch('media/gone/stray/source.mp3');
    final kept = touch('media/kept/teacher_1/source.mp3');

    await deletePieceMediaFolder('gone', docs: docs);
    expect(Directory('${docs.path}/media/gone').existsSync(), isFalse);
    expect(kept.existsSync(), isTrue);
  });

  test('a missing folder is fine', () async {
    await deletePieceMediaFolder('never_had_media', docs: docs);
  });

  test('refuses ids that would name media/ itself or reach outside it',
      () async {
    final inMedia = touch('media/other/x/a.mp3');
    final outside = touch('scanned_pieces/p.musicxml');
    for (final id in ['', '.', '..', '../scanned_pieces', 'a/b', r'a\b']) {
      await deletePieceMediaFolder(id, docs: docs);
    }
    expect(inMedia.existsSync(), isTrue);
    expect(outside.existsSync(), isTrue);
  });
}

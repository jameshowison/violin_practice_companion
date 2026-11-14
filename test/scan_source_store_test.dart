import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/omr_service_base.dart';
import 'package:violin_practice_companion/services/scan_source_store_io.dart';

void main() {
  late Directory docs;

  setUp(() async => docs = await Directory.systemTemp.createTemp('scan_sources'));
  tearDown(() async => docs.delete(recursive: true));

  final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  final jpg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 4, 5]);

  List<String> names(String pieceId) {
    final dir = Directory('${docs.path}/scan_sources/$pieceId');
    if (!dir.existsSync()) return [];
    return [for (final f in dir.listSync()) f.uri.pathSegments.last]..sort();
  }

  test('keeps each page original and crop, named by page and by content type',
      () async {
    await ScanSourceStore(root: docs).save('tune_1', [
      ScanSourcePage(original: jpg, cropped: png),
      ScanSourcePage(original: png, cropped: jpg),
    ]);
    expect(names('tune_1'), [
      'page_1_crop.png',
      'page_1_original.jpg',
      'page_2_crop.jpg',
      'page_2_original.png',
    ]);
    expect(File('${docs.path}/scan_sources/tune_1/page_1_crop.png').readAsBytesSync(),
        png);
  });

  test('delete removes them, and is a no-op for a piece never scanned',
      () async {
    final store = ScanSourceStore(root: docs);
    await store.save('tune_1', [ScanSourcePage(original: jpg, cropped: png)]);
    await store.delete('tune_1');
    await store.delete('never_scanned');
    expect(names('tune_1'), isEmpty);
  });

  test('originals come back in page order, crops left out', () async {
    final store = ScanSourceStore(root: docs);
    final pages = [
      for (var i = 0; i < 11; i++)
        ScanSourcePage(
            original: Uint8List.fromList([0xff, 0xd8, 0xff, i]), cropped: png),
    ];
    await store.save('tune_1', pages);
    expect(await store.originalCount('tune_1'), 11);
    // page_10 sorts before page_2 by name; it must not by page.
    expect([for (final b in await store.originals('tune_1')) b.last],
        List.generate(11, (i) => i));
    expect(await store.originals('never_scanned'), isEmpty);
    expect(await store.originalCount('never_scanned'), 0);
  });
}

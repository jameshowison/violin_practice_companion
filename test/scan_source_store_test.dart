import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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

  /// A real, compressible page: white with dark "staff lines" — what a
  /// cropper PNG of printed music looks like.
  Uint8List pagePng({bool alpha = false}) {
    final page = img.Image(width: 600, height: 400, numChannels: alpha ? 4 : 3)
      ..clear(alpha ? img.ColorRgba8(0, 0, 0, 0) : img.ColorRgb8(255, 255, 255));
    // Paper grain and camera noise, which is what makes a real crop's PNG
    // big; a flat synthetic page is smaller as PNG than as any JPEG.
    var seed = 7;
    for (var y = 0; y < 400; y++) {
      for (var x = 0; x < 600; x++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        if (alpha) {
          // Transparent, over dark noise: comes out black unless flattened.
          final v = seed % 20;
          page.setPixelRgba(x, y, v, v, v, 0);
        } else {
          final v = 235 + seed % 20;
          page.setPixelRgba(x, y, v, v, v - 3, 255);
        }
      }
    }
    for (var y = 40; y < 400; y += 12) {
      img.drawLine(page, x1: 20, y1: y, x2: 580, y2: y,
          color: img.ColorRgb8(20, 20, 20));
    }
    return img.encodePng(page);
  }

  test('compress turns PNG pages into smaller JPEGs, leaves JPEG alone',
      () async {
    final store = ScanSourceStore(root: docs);
    final png = pagePng();
    await store.save('tune_1', [ScanSourcePage(original: jpg, cropped: png)]);
    await store.compress('tune_1');
    expect(names('tune_1'), ['page_1_crop.jpg', 'page_1_original.jpg']);
    final crop =
        File('${docs.path}/scan_sources/tune_1/page_1_crop.jpg').readAsBytesSync();
    expect(crop.sublist(0, 3), [0xff, 0xd8, 0xff]);
    expect(crop.length, lessThan(png.length));
    expect(img.decodeJpg(crop)!.width, 600, reason: 'full resolution kept');
    // The original was already JPEG (stub bytes): byte-for-byte untouched.
    expect(
        File('${docs.path}/scan_sources/tune_1/page_1_original.jpg')
            .readAsBytesSync(),
        jpg);
  });

  test('a transparent page is flattened onto white, not black', () async {
    final store = ScanSourceStore(root: docs);
    await store.save(
        'tune_1', [ScanSourcePage(original: jpg, cropped: pagePng(alpha: true))]);
    await store.compress('tune_1');
    final crop = img.decodeJpg(
        File('${docs.path}/scan_sources/tune_1/page_1_crop.jpg').readAsBytesSync())!;
    expect(crop.getPixel(5, 5).r, greaterThan(240));
  });

  test('compressAll covers every piece, and undecodable bytes stay as they are',
      () async {
    final store = ScanSourceStore(root: docs);
    await store.save('a', [ScanSourcePage(original: pagePng(), cropped: png)]);
    await store.save('b', [ScanSourcePage(original: pagePng(), cropped: jpg)]);
    await store.compressAll();
    // `png` is stub bytes no decoder accepts: kept rather than lost.
    expect(names('a'), ['page_1_crop.png', 'page_1_original.jpg']);
    expect(names('b'), ['page_1_crop.jpg', 'page_1_original.jpg']);
  });
}

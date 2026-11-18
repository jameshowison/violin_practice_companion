// Corpus eval for scan title recognition: runs the real path (crop location,
// search region, PaddleOCR via homr_flutter's TextReader, pickTitle) over the
// dev library's saved scan sources, and prints what it read next to the
// piece's stored title, with timings. Needs the models
// (scripts/fetch_omr_models.sh). Results so far: docs/title_ocr.md. Run on a
// simulator; the dev library is read straight off the host's disk:
//
//   flutter test integration_test/title_recognition_test.dart -d dev-iphone-se \
//     --dart-define=TITLE_CORPUS_DIR=$PWD/../violin_dev_library
//
// On the Android emulator the host's disk isn't visible: push the corpus to
// /data/local/tmp (the app's own dirs are wiped when the test reinstalls)
// with `bash scripts/push_title_corpus.sh <library> <serial>`, and pass
// TITLE_CORPUS_DIR=/data/local/tmp/title_corpus.
//
// Skipped without TITLE_CORPUS_DIR. It reports rather than asserts: the
// stored titles are whatever was typed at scan time ("allegretto",
// "book2 chorus"), so a mismatch is for reading, not for failing.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:violin_practice_companion/services/title_recognizer_io.dart';
import 'package:violin_practice_companion/services/title_region.dart';

const _corpusDir = String.fromEnvironment('TITLE_CORPUS_DIR');

String _fmt(ui.Rect? r) => r == null
    ? '—'
    : '[${[r.left, r.top, r.right, r.bottom].map((v) => v.toStringAsFixed(2)).join(', ')}]';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('title recognition over the dev library scan sources', (tester) async {
    final root = Directory('$_corpusDir/scan_sources');
    final titles = (jsonDecode(File('$_corpusDir/state.json').readAsStringSync())['titles'] as Map)
        .cast<String, String>();
    final dirs = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    var hits = 0;
    final ms = <int>[];
    final rows = <String>[];
    for (final dir in dirs) {
      final id = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      File? find(String stem) => dir
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith(stem))
          .firstOrNull;
      final original = find('page_1_original'), crop = find('page_1_crop');
      if (original == null || crop == null) continue;

      await tester.runAsync(() async {
        final o = await original.readAsBytes(), c = await crop.readAsBytes();
        final sw = Stopwatch()..start();
        final rect = await TitleRecognizer.locateCropIn(o, c);
        final locateMs = sw.elapsedMilliseconds;
        final region = titleSearchRegion(rect ?? const ui.Rect.fromLTWH(0, 0, 1, 1));
        final expected = titles[id] ?? '?';
        sw.reset();
        final lines = await TitleRecognizer.readLines(o, region);
        final readMs = sw.elapsedMilliseconds;
        ms.add(readMs);
        final title = pickTitle(lines);
        final hit = (title ?? '').toLowerCase().contains(expected.toLowerCase());
        if (hit) hits++;
        // No raw OCR text: a page can carry lyrics, which must not leave the
        // device. Only the chosen title, the stored one, and numbers.
        final winner = lines
            .where((l) => l.text.trim().replaceAll(RegExp(r'\s+'), ' ') == title)
            .firstOrNull;
        rows.add('$id   stored: $expected\n'
            '    crop ${_fmt(rect)} (${locateMs}ms)  region ${_fmt(region)}\n'
            '    ${hit ? '✓' : '✗'} ${title ?? '—'}   (${lines.length} lines, ${readMs}ms'
            '${winner == null ? '' : ', h=${(winner.box.height * 1000).round()} c=${winner.confidence.toStringAsFixed(2)}'})');
      });
    }
    final sorted = [...ms]..sort();
    String at(int i) => sorted.isEmpty ? '—' : '${sorted[i]}ms';
    // ignore: avoid_print
    print('\n${rows.join('\n')}\n\n$hits/${rows.length} contain the stored title; '
        'reading: median ${at(sorted.length ~/ 2)}, worst ${at(sorted.length - 1)}, '
        'first ${ms.isEmpty ? '—' : '${ms.first}ms'}\n');
  }, skip: _corpusDir.isEmpty);
}

// Screen-to-screen sharing eval: runs the real recogniser (homr_flutter's
// OmrOrchestrator, as OmrService calls it) over screenshots of the app's own
// score view, so "can a student scan the teacher's screen?" has a number.
// Run on a simulator; images are read from, and MusicXML written back to, the
// host's disk:
//
//   flutter test integration_test/screen_scan_test.dart -d dev-iphone \
//     --dart-define=SCREEN_SCAN_DIR=/abs/path/to/shots
//
// SCREEN_SCAN_DIR holds one subdirectory per case; each subdirectory's PNG/JPG
// files, in name order, are the pages of one piece. The recognised MusicXML
// is written next to them as `out.musicxml`. Score it against the piece's own
// score with `python3 scripts/omr_eval/score_screen_scan.py`.
//
// The crop step is not exercised (it is the user's finger in a native view):
// put already-cropped images in the case directory. Skipped without the define.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homr_flutter/homr_flutter.dart';
import 'package:integration_test/integration_test.dart';

const _dir = String.fromEnvironment('SCREEN_SCAN_DIR');
const _only = String.fromEnvironment('SCREEN_SCAN_ONLY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recognise app screenshots', (tester) async {
    final cases = Directory(_dir).listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final orchestrator = OmrOrchestrator(models: OmrModels.inAssetDir('assets/engine/omr_models'));
    final rows = <String>[];
    for (final dir in cases) {
      final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (_only.isNotEmpty && !name.contains(_only)) continue;
      final pages = dir
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (pages.isEmpty) continue;
      await tester.runAsync(() async {
        final sw = Stopwatch()..start();
        try {
          final xml = await orchestrator.recogniseMultiPage(
            [for (final p in pages) await p.readAsBytes()],
            title: name,
          );
          File('${dir.path}/out.musicxml').writeAsStringSync(xml);
          rows.add('$name: ${pages.length} page(s) ok in ${sw.elapsedMilliseconds}ms');
        } catch (e) {
          File('${dir.path}/out.musicxml').writeAsStringSync('');
          File('${dir.path}/out.error').writeAsStringSync('$e');
          rows.add('$name: FAILED $e');
        }
      });
    }
    // ignore: avoid_print
    print('\n[screen_scan]\n${rows.join('\n')}\n');
  }, skip: _dir.isEmpty, timeout: const Timeout(Duration(minutes: 30)));
}

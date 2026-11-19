import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/rendered_score_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('rendered_cache_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => cache.path);
    // No encoder under test: the WAV is kept, as on a platform without one.
  });

  tearDown(() => cache.delete(recursive: true));

  final piece = MusicXmlParser().parse(
      File('assets/library/lightly_row/score.musicxml').readAsStringSync());

  test('renders once, then reads back; concurrent asks share one render',
      () async {
    final c = RenderedScoreCache();
    final data = MidiGenerator.forTest().generate(piece, 100);
    // Both complete: a whenComplete that returned its own future hung here.
    final both = await Future.wait([
      c.obtain(piece, data, 100),
      c.obtain(piece, data, 100),
    ]).timeout(const Duration(seconds: 30));
    expect(both[0], isNotNull);
    expect(both[1]!.path, both[0]!.path);
    expect(both[0]!.path, endsWith('.wav'));
    expect(both[0]!.prerollSeconds, closeTo(7.2, 1e-9));
    expect(both[0]!.anchors.first.audioSec, closeTo(7.2, 1e-9));

    final again = await RenderedScoreCache()
        .obtain(piece, data, 100)
        .timeout(const Duration(seconds: 5));
    expect(again!.path, both[0]!.path);
    expect(again.anchors.length, both[0]!.anchors.length);
  });

  test('a different tempo is a different file', () async {
    final c = RenderedScoreCache();
    final a = await c.obtain(
        piece, MidiGenerator.forTest().generate(piece, 100), 100);
    final b =
        await c.obtain(piece, MidiGenerator.forTest().generate(piece, 85), 85);
    expect(a!.path, isNot(b!.path));
  });
}

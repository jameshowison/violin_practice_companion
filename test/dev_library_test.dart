import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/services/dev_library_io.dart';

/// The push half of the dev-library sync, one test per row of the three-way
/// table in [DevLibraryIngester]'s doc comment. The pull half is the same table
/// run the other way, in `scripts/pull_dev_library.sh`.
void main() {
  late Directory docs;

  Directory stage() => Directory('${docs.path}/$devLibraryFolder');

  Future<void> write(Directory root, String rel, String content) async {
    final f = File('${root.path}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  String? read(String rel) {
    final f = File('${docs.path}/$rel');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  Future<void> stageLibrary({
    Map<String, String> files = const {},
    Map<String, String> titles = const {},
    Map<String, List<Map<String, Object?>>> media = const {},
    Object? library,
  }) async {
    if (await stage().exists()) await stage().delete(recursive: true);
    await stage().create(recursive: true);
    for (final MapEntry(:key, :value) in files.entries) {
      await write(stage(), key, value);
    }
    await write(stage(), 'state.json', jsonEncode({
      'version': 2,
      'titles': titles,
      'pieceMedia': media,
      'pieceLibrary': library,
    }));
  }

  Map<String, Object?> row(String id, {String label = 'x'}) => {
        'id': id,
        'label': label,
        'kind': 'imported',
        'alignmentKey': 'media:p:$id',
        'audio': {'storage': 'appFile', 'path': 'media/p/$id/source.mp3'},
        'analysis': {'storage': 'appFile', 'path': 'media/p/$id/source.mp3'},
        'avOffsetMs': 0,
      };

  Future<DevLibraryReport> ingest() async =>
      (await DevLibraryIngester(root: docs).ingest())!;

  Future<List<String>> mediaIds(String pieceId) async {
    final raw = (await SharedPreferences.getInstance())
        .getString('pieceMedia.$pieceId');
    if (raw == null) return [];
    return [for (final r in jsonDecode(raw) as List) r['id'] as String];
  }

  Future<Map<String, String>> indexTitles() async {
    final raw = read('scanned_pieces/index.json');
    if (raw == null) return {};
    return {
      for (final r in (jsonDecode(raw) as Map)['pieces'] as List)
        r['id'] as String: r['title'] as String,
    };
  }

  const score = 'scanned_pieces/tune_1.musicxml';
  String xml(String title) =>
      '<score-partwise><work><work-title>$title</work-title></work></score-partwise>';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('dev_library_test');
  });

  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  test('no staged library: does nothing at all', () async {
    expect(await DevLibraryIngester(root: docs).ingest(), isNull);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('fresh device: everything in the library lands, ids intact', () async {
    await stageLibrary(
      files: {
        score: xml('Tune'),
        'section_overrides/tune_1.sections.json': '{"sections":[]}',
        'media/p/m1/source.mp3': 'audio',
      },
      titles: {'tune_1': 'Tune'},
      media: {'p': [row('m1')]},
      library: {'collections': []},
    );
    final report = await ingest();
    expect(report.conflicts, isEmpty);
    expect(read(score), xml('Tune'));
    expect(read('media/p/m1/source.mp3'), 'audio');
    expect(await indexTitles(), {'tune_1': 'Tune'});
    expect(await mediaIds('p'), ['m1']);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('pieceLibrary')!), {'collections': []});
  });

  test('a second launch is a no-op', () async {
    await stageLibrary(files: {score: xml('Tune')}, titles: {'tune_1': 'Tune'});
    await ingest();
    final again = await ingest();
    expect(again.written + again.deleted + again.kept, 0);
  });

  test('library changed, device untouched: the library is applied', () async {
    await stageLibrary(files: {score: xml('Tune')}, media: {'p': [row('m1')]});
    await ingest();
    await stageLibrary(
        files: {score: xml('Tune v2')},
        media: {'p': [row('m1', label: 'renamed'), row('m2')]});
    final report = await ingest();
    expect(read(score), xml('Tune v2'));
    expect(await mediaIds('p'), ['m1', 'm2']);
    expect(report.conflicts, isEmpty);
  });

  test('library deleted something, device untouched: deleted here too',
      () async {
    await stageLibrary(files: {score: xml('Tune')}, media: {'p': [row('m1')]});
    await ingest();
    await stageLibrary();
    final report = await ingest();
    expect(read(score), isNull);
    expect(await mediaIds('p'), isEmpty);
    expect(report.deleted, 2);
  });

  test('device changed, library untouched: the device edit is kept for the '
      'next pull', () async {
    await stageLibrary(files: {score: xml('Tune')});
    await ingest();
    await write(docs, score, xml('Edited on device'));
    // A piece made on this device since the last sync, too.
    await write(docs, 'scanned_pieces/new_2.musicxml', xml('New'));

    final report = await ingest();
    expect(read(score), xml('Edited on device'));
    expect(read('scanned_pieces/new_2.musicxml'), xml('New'));
    expect(report.kept, greaterThanOrEqualTo(2));
    expect(report.conflicts, isEmpty);
    // Still pending: the base was not advanced, so the pull will see it.
    expect((await ingest()).kept, greaterThanOrEqualTo(2));
  });

  test('a piece deleted on the device is not resurrected', () async {
    await stageLibrary(files: {score: xml('Tune')});
    await ingest();
    await File('${docs.path}/$score').delete();
    final report = await ingest();
    expect(read(score), isNull);
    expect(report.kept, 1);
  });

  test('both sides changed: conflict, the device copy is kept', () async {
    await stageLibrary(files: {score: xml('Tune')});
    await ingest();
    await write(docs, score, xml('Device edit'));
    await stageLibrary(files: {score: xml('Library edit')});
    final report = await ingest();
    expect(read(score), xml('Device edit'));
    expect(report.conflicts, ['file:$score']);
  });

  test('a fresh device takes the library blob over its own first-launch seed',
      () async {
    SharedPreferences.setMockInitialValues(
        {'pieceLibrary': jsonEncode({'seedVersion': 1})});
    await stageLibrary(library: {'seedVersion': 1, 'collections': ['x']});
    final report = await ingest();
    expect(report.conflicts, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('pieceLibrary')!)['collections'], ['x']);
  });

  test('a device blob is never deleted when the library has none', () async {
    // Regression: the fresh-device rule above once applied with no library
    // blob too, and the push deleted the device's only copy.
    SharedPreferences.setMockInitialValues(
        {'pieceLibrary': jsonEncode({'collections': ['mine']})});
    await stageLibrary();
    final report = await ingest();
    expect(report.deleted, 0);
    expect(report.kept, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('pieceLibrary')!)['collections'], ['mine']);
  });

  test('device media the library has never seen are kept for the pull',
      () async {
    SharedPreferences.setMockInitialValues(
        {'pieceMedia.p': jsonEncode([row('mine')])});
    await stageLibrary(media: {'p': [row('m1')]});
    final report = await ingest();
    expect(await mediaIds('p'), ['mine', 'm1']);
    expect(report.kept, 1);
  });

  test('scan sources travel with the library', () async {
    await stageLibrary(files: {'scan_sources/tune_1/page_1_crop.jpg': 'crop'});
    await ingest();
    expect(read('scan_sources/tune_1/page_1_crop.jpg'), 'crop');
  });

  test('fingerprints match the Python pull script', () {
    // The same two values, computed by scripts/pull_dev_library.sh's
    // fnv1a / canonical_json, must give these exact strings.
    expect(fnv1a(utf8.encode('hello')), '4f9f2cab');
    expect(canonicalJson({'b': 1, 'a': [true, null, 'é', 0.5]}),
        '{"a":[true,null,"é",0.5],"b":1}');
  });
}

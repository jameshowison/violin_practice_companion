import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/piece_storage_io.dart';

/// A minimal score carrying its own `<work-title>`, which is how a title is
/// recovered when the index doesn't know it. Real imported pieces all carry one
/// (the ABC converter writes it).
String scoreXml(String title) => '''
<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0">
  <work><work-title>$title</work-title></work>
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1"><measure number="1"><note><rest/><duration>4</duration></note></measure></part>
</score-partwise>
''';

void main() {
  late Directory root;
  late PieceStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('piece_storage_test');
    storage = PieceStorage(root: root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Directory scannedDir() => Directory('${root.path}/scanned_pieces');
  File indexFile() => File('${scannedDir().path}/index.json');

  Future<void> writePiece(String id, String title) async {
    await scannedDir().create(recursive: true);
    await File('${scannedDir().path}/$id.musicxml').writeAsString(scoreXml(title));
  }

  /// The pre-fix index: a bare JSON array whose rows carry an ABSOLUTE path.
  Future<void> writeLegacyIndex(List<(String id, String title)> rows,
      {required String container}) async {
    await scannedDir().create(recursive: true);
    await indexFile().writeAsString(json.encode([
      for (final (id, title) in rows)
        {
          'id': id,
          'title': title,
          'musicXmlFilePath':
              '/var/mobile/Containers/Data/Application/$container/Documents/scanned_pieces/$id.musicxml',
        },
    ]));
  }

  group('the reinstall bug', () {
    test('a legacy index whose paths point at a DEAD container still loads every '
        'piece', () async {
      // Exactly the observed failure: index.json recorded absolute paths under
      // container UUIDs that no longer exist, while the files themselves sit in
      // the current container. Before the fix the list rendered but every piece
      // failed to open.
      await writePiece('old_joe_clark_1785451113047', 'Old Joe Clark');
      await writePiece('reel_1785452349623', 'A Reel');
      await writeLegacyIndex(
        [
          ('old_joe_clark_1785451113047', 'Old Joe Clark'),
          ('reel_1785452349623', 'A Reel'),
        ],
        container: 'E28A0002-B939-4612-8BF9-774F617B7A2F', // long gone
      );

      final pieces = await storage.loadScannedPieces();

      expect(pieces.map((p) => p.title), ['Old Joe Clark', 'A Reel']);
      // Every path is recomputed against the CURRENT root, so it resolves...
      for (final p in pieces) {
        expect(p.musicXmlFilePath, startsWith(root.path));
        expect(File(p.musicXmlFilePath!).existsSync(), isTrue);
        // ...and the content is actually readable, which is what used to throw.
        expect(await storage.readScannedMusicXml(p.musicXmlFilePath!),
            contains('<work-title>'));
      }
    });

    test('the legacy index is repaired in place, dropping the stale path', () async {
      await writePiece('tune_1', 'Tune One');
      await writeLegacyIndex([('tune_1', 'Tune One')], container: 'DEAD-BEEF');

      await storage.loadScannedPieces();

      final rewritten = json.decode(await indexFile().readAsString());
      expect(rewritten, isA<Map>());
      expect(rewritten['version'], 2);
      expect(rewritten['pieces'], [
        {'id': 'tune_1', 'title': 'Tune One'}
      ]);
      // The field that went stale is gone entirely.
      expect(await indexFile().readAsString(), isNot(contains('musicXmlFilePath')));
    });

    test('a stale absolute handle still reads, by falling back to the filename',
        () async {
      await writePiece('tune_1785451113047', 'Tune');
      const stale =
          '/var/mobile/Containers/Data/Application/GONE/Documents/scanned_pieces/tune_1785451113047.musicxml';
      expect(await storage.readScannedMusicXml(stale), contains('<work-title>'));
    });

    test('a handle that matches nothing anywhere still throws', () async {
      await expectLater(
        storage.readScannedMusicXml('/nope/missing.musicxml'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('the directory is the source of truth', () {
    test('pieces are recovered with NO index at all, titled from the score',
        () async {
      await writePiece('lost_1785451113047', 'Recovered Tune');
      expect(indexFile().existsSync(), isFalse);

      final pieces = await storage.loadScannedPieces();

      expect(pieces, hasLength(1));
      expect(pieces.single.title, 'Recovered Tune');
      expect(indexFile().existsSync(), isTrue); // and the cache is rebuilt
    });

    test('an index row whose file is gone becomes no piece', () async {
      await writePiece('present_1', 'Present');
      await writeLegacyIndex(
        [('present_1', 'Present'), ('deleted_2', 'Deleted')],
        container: 'X',
      );

      final pieces = await storage.loadScannedPieces();

      expect(pieces.map((p) => p.id), ['present_1']);
      // The orphan row is pruned — the index was append-only before, with no
      // delete path anywhere in the app.
      expect(await indexFile().readAsString(), isNot(contains('deleted_2')));
    });

    test('a file the index has never heard of is picked up', () async {
      await writePiece('indexed_1', 'Indexed');
      await writePiece('stranger_2', 'Stranger');
      await writeLegacyIndex([('indexed_1', 'Indexed')], container: 'X');

      final pieces = await storage.loadScannedPieces();

      expect(pieces.map((p) => p.title), containsAll(['Indexed', 'Stranger']));
    });

    test('a corrupt index loses titles, not songs', () async {
      await writePiece('tune_1', 'From The Score');
      await scannedDir().create(recursive: true);
      await indexFile().writeAsString('{ this is not json');

      final pieces = await storage.loadScannedPieces();

      expect(pieces.single.title, 'From The Score');
    });

    test('an empty store is empty, and does not create an index', () async {
      expect(await storage.loadScannedPieces(), isEmpty);
      expect(indexFile().existsSync(), isFalse);
    });
  });

  group('title precedence', () {
    test('the index wins over the score title', () async {
      await writePiece('t_1', 'Score Title');
      await writeLegacyIndex([('t_1', 'Index Title')], container: 'X');
      final pieces = await storage.loadScannedPieces();
      expect(pieces.single.title, 'Index Title');
    });

    test('a score with no title at all falls back to the id', () async {
      await scannedDir().create(recursive: true);
      await File('${scannedDir().path}/untitled_9.musicxml')
          .writeAsString('<score-partwise><part id="P1"/></score-partwise>');
      final pieces = await storage.loadScannedPieces();
      expect(pieces.single.title, 'untitled_9');
    });
  });

  group('round trips', () {
    test('save then load returns the piece, readable', () async {
      final saved = await storage.saveScannedPiece('New Tune', scoreXml('New Tune'));

      final pieces = await storage.loadScannedPieces();
      expect(pieces.map((p) => p.id), [saved.id]);
      expect(pieces.single.title, 'New Tune');
      expect(await storage.readScannedMusicXml(pieces.single.musicXmlFilePath!),
          contains('New Tune'));
    });

    test('save leaves an index that load agrees with, unchanged on reload',
        () async {
      await storage.saveScannedPiece('One', scoreXml('One'));
      await storage.saveScannedPiece('Two', scoreXml('Two'));
      final afterSave = await indexFile().readAsString();

      await storage.loadScannedPieces();

      // No repair needed the second time: save already left it consistent.
      expect(await indexFile().readAsString(), afterSave);
    });

    test('update overwrites in place without touching the index', () async {
      final saved = await storage.saveScannedPiece('Tune', scoreXml('Tune'));
      final before = await indexFile().readAsString();

      await storage.updateScannedPieceFile(
          saved.musicXmlFilePath!, scoreXml('Edited'));

      expect(await storage.readScannedMusicXml(saved.musicXmlFilePath!),
          contains('Edited'));
      expect(await indexFile().readAsString(), before);
    });

    test('editable fixtures resolve by id, never by a stored path', () async {
      expect(await storage.fixtureFilePathIfExists('lightly_row'), isNull);
      final path = await storage.writeFixtureFile('lightly_row', scoreXml('LR'));
      expect(await storage.fixtureFilePathIfExists('lightly_row'), path);
      expect(await storage.readScannedMusicXml(path), contains('LR'));
    });

    test('section overrides round trip', () async {
      expect(await storage.loadSectionsOverride('p1'), isNull);
      await storage.saveSectionsOverride('p1', [
        {'label': 'A', 'startMeasure': 1}
      ]);
      expect(await storage.loadSectionsOverride('p1'), [
        {'label': 'A', 'startMeasure': 1}
      ]);
    });
  });
}

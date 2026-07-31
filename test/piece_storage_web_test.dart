import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/services/piece_storage_web.dart';

/// The web backend is plain Dart over `shared_preferences` — no `dart:html` — so
/// it is directly importable here and testable against the in-memory mock store.

String scoreXml(String title) => '''
<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0">
  <work><work-title>$title</work-title></work>
  <part id="P1"><measure number="1"><note><rest/><duration>4</duration></note></measure></part>
</score-partwise>
''';

void main() {
  late PieceStorage storage;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    storage = PieceStorage();
  });

  test('web supports editing now that the store is real', () {
    // The old stub reported false, which disabled the measure editor and made
    // ABC import throw UnsupportedError outright.
    expect(storageSupportsEditing, isTrue);
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

    test('the handle is a storage key, not a filesystem path', () async {
      final saved = await storage.saveScannedPiece('Tune', scoreXml('Tune'));
      expect(saved.musicXmlFilePath, startsWith('prefs:piece:'));
      expect(saved.musicXmlFilePath, contains(saved.id));
    });

    test('update overwrites the stored score', () async {
      final saved = await storage.saveScannedPiece('Tune', scoreXml('Tune'));
      await storage.updateScannedPieceFile(
          saved.musicXmlFilePath!, scoreXml('Edited'));
      expect(await storage.readScannedMusicXml(saved.musicXmlFilePath!),
          contains('Edited'));
    });

    test('editable fixtures round trip by id', () async {
      expect(await storage.fixtureFilePathIfExists('lightly_row'), isNull);
      final handle = await storage.writeFixtureFile('lightly_row', scoreXml('LR'));
      expect(await storage.fixtureFilePathIfExists('lightly_row'), handle);
      expect(await storage.readScannedMusicXml(handle), contains('LR'));
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

  group('the key set is the index', () {
    test('a piece whose title key is missing recovers it from the score',
        () async {
      final saved = await storage.saveScannedPiece('Stored Title', scoreXml('Score Title'));
      // Simulate a half-written / partially-cleared store.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('piece.${saved.id}.title');

      final pieces = await storage.loadScannedPieces();
      expect(pieces.single.title, 'Score Title');
    });

    test('a titleless score falls back to the id', () async {
      final saved = await storage.saveScannedPiece(
          'T', '<score-partwise><part id="P1"/></score-partwise>');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('piece.${saved.id}.title');

      final pieces = await storage.loadScannedPieces();
      expect(pieces.single.title, saved.id);
    });

    test('unrelated keys are ignored — including the staff-zoom prefs', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('measuresPerLine.lightly_row', 4);
      await prefs.setString('sections.whatever', '{}');
      expect(await storage.loadScannedPieces(), isEmpty);
    });

    test('an empty store is empty', () async {
      expect(await storage.loadScannedPieces(), isEmpty);
    });
  });

  group('ordering', () {
    test('pieces come back oldest first, by the timestamp in the id', () async {
      // Ids embed millisecondsSinceEpoch, so saves are strictly increasing; web
      // storage has no insertion order of its own to rely on.
      final first = await storage.saveScannedPiece('Alpha', scoreXml('Alpha'));
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final second = await storage.saveScannedPiece('Zulu', scoreXml('Zulu'));
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final third = await storage.saveScannedPiece('Bravo', scoreXml('Bravo'));

      final ids = (await storage.loadScannedPieces()).map((p) => p.id).toList();
      expect(ids, [first.id, second.id, third.id],
          reason: 'chronological, not alphabetical');
    });
  });

  group('handles', () {
    test('a malformed handle is rejected rather than silently returning null',
        () async {
      for (final bad in ['', 'piece:x', 'prefs:', 'prefs:bogus:x']) {
        await expectLater(
          storage.readScannedMusicXml(bad),
          throwsA(isA<ArgumentError>()),
          reason: 'handle "$bad"',
        );
      }
    });

    test('a well-formed handle for a missing piece throws', () async {
      await expectLater(
        storage.readScannedMusicXml('prefs:piece:nope_1'),
        throwsA(isA<StateError>()),
      );
    });
  });
}

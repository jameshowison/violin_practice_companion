import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/scan_source_store_io.dart';
import 'package:violin_practice_companion/services/abc_source_store_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_library.dart';
import 'package:violin_practice_companion/services/piece_repository.dart';
import 'package:violin_practice_companion/services/piece_storage_io.dart';
import 'package:violin_practice_companion/services/providers.dart';

/// The first provider-level test in the repo.
///
/// [PieceRepository.loadAll] cannot run headless — its bundled fixtures need
/// `rootBundle` — so `piecesProvider` is overridden directly rather than the
/// repository behind it. The repository is still overridden separately, against
/// a temp directory, for the delete path.
void main() {
  late Directory root;

  Piece piece(String id) => Piece(
      id: id, title: id, musicXmlAssetPath: 'a/$id.xml', sections: const []);

  final all = [piece('a'), piece('b'), piece('c')];

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('piece_library_providers');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  ProviderContainer makeContainer({List<Piece>? pieces}) {
    final container = ProviderContainer(overrides: [
      piecesProvider.overrideWith((ref) async => pieces ?? all),
      pieceRepositoryProvider.overrideWithValue(
          PieceRepository(storage: PieceStorage(root: root))),
      scanSourceStoreProvider.overrideWithValue(ScanSourceStore(root: root)),
      abcSourceStoreProvider.overrideWithValue(AbcSourceStore(root: root)),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// Settles the library's async build so `valueOrNull` is populated.
  ///
  /// Note this also runs the first-launch seeding. That no longer creates the
  /// "OMR demos" collection (see the last test below), but [newCollection]
  /// still picks the one it made rather than reaching for
  /// `collectionsProvider.single`.
  Future<PieceLibraryNotifier> library(ProviderContainer c) async {
    await c.read(libraryProvider.future);
    return c.read(libraryProvider.notifier);
  }

  Future<String> newCollection(
      ProviderContainer c, PieceLibraryNotifier lib, String name) async {
    await lib.createCollection(name);
    return c.read(collectionsProvider).last.id;
  }

  test('pieceCollectionsProvider derives membership without storing it',
      () async {
    final c = makeContainer();
    await c.read(piecesProvider.future);
    final lib = await library(c);

    final book1 = await newCollection(c, lib, 'Book 1');
    final week = await newCollection(c, lib, 'This week');
    await lib.setTags('a', {book1, week});

    expect(c.read(pieceCollectionsProvider('a')), {book1, week});
    expect(c.read(pieceCollectionsProvider('b')), isEmpty);
  });

  group('deleting a piece', () {
    /// A real user piece on disk, so the repository's delete path has something
    /// to remove.
    Future<Piece> saveUserPiece(ProviderContainer c, String title) =>
        c.read(pieceRepositoryProvider).savePiece(title, '<score-partwise/>');

    test('clears the selection when it was the deleted piece', () async {
      final c = makeContainer();
      final saved = await saveUserPiece(c, 'Throwaway');
      final withSaved = makeContainer(pieces: [...all, saved]);
      await withSaved.read(piecesProvider.future);
      await library(withSaved);
      withSaved.read(selectedPieceProvider.notifier).state = saved;

      await withSaved.read(libraryActionsProvider).deletePiece(saved.id);

      expect(withSaved.read(selectedPieceProvider), isNull);
      expect(withSaved.read(measureSelectionProvider), isNull);
    });

    test('leaves an unrelated selection alone', () async {
      final c = makeContainer();
      final saved = await saveUserPiece(c, 'Throwaway');
      final withSaved = makeContainer(pieces: [...all, saved]);
      await withSaved.read(piecesProvider.future);
      await library(withSaved);
      withSaved.read(selectedPieceProvider.notifier).state = all.first;

      await withSaved.read(libraryActionsProvider).deletePiece(saved.id);

      expect(withSaved.read(selectedPieceProvider), all.first);
    });

    test('forgets the piece everywhere the library knew it', () async {
      final c = makeContainer();
      final saved = await saveUserPiece(c, 'Throwaway');
      final withSaved = makeContainer(pieces: [...all, saved]);
      await withSaved.read(piecesProvider.future);
      final lib = await library(withSaved);
      final id = await newCollection(withSaved, lib, 'This week');
      await lib.setTags(saved.id, {id});
      await lib.renamePiece(saved.id, 'Renamed');

      await withSaved.read(libraryActionsProvider).deletePiece(saved.id);

      final after = withSaved.read(libraryProvider).value!;
      expect(after.collectionById(id)!.pieceIds, isEmpty);
      expect(after.titleOverrides, isEmpty);
      expect(await PieceStorage(root: root).loadScannedPieces(), isEmpty,
          reason: 'the MusicXML itself is gone from the store');
    });

    test('refuses a bundled fixture — those are hidden, not deleted', () async {
      final c = makeContainer();
      await c.read(piecesProvider.future);
      await library(c);

      await expectLater(
        c.read(libraryActionsProvider).deletePiece('lightly_row'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test('first load seeds nothing to hide: no OMR demos ship any more',
      () async {
    // The abc_/homr_ comparison pairs are test data now (test/fixtures/omr),
    // so step 1 of seeding has no ids and creates no "OMR demos" collection.
    // The step itself is covered with synthetic ids in piece_library_test.
    final c = makeContainer();
    final lib = await c.read(libraryProvider.future);

    expect(lib.hiddenIds, isEmpty);
    expect(lib.collections.where((x) => x.name == omrDemoCollectionName),
        isEmpty);
    expect(lib.seedVersion, currentSeedVersion);
  });
}

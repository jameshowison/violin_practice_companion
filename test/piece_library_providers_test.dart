import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_library.dart';
import 'package:violin_practice_companion/services/piece_repository.dart';
import 'package:violin_practice_companion/services/piece_storage_io.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';

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
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// Settles the library's async build so `valueOrNull` is populated.
  ///
  /// Note this also runs the first-launch seeding, so the library already holds
  /// the "OMR demos" collection — hence [newCollection] below rather than
  /// reaching for `collectionsProvider.single`.
  Future<PieceLibraryNotifier> library(ProviderContainer c) async {
    await c.read(libraryProvider.future);
    return c.read(libraryProvider.notifier);
  }

  Future<String> newCollection(
      ProviderContainer c, PieceLibraryNotifier lib, String name) async {
    await lib.createCollection(name);
    return c.read(collectionsProvider).last.id;
  }

  group('visiblePiecesProvider', () {
    test('drops hidden pieces, with no mode that can put them back', () async {
      // There is deliberately no "show hidden" flag on this list any more. The
      // one that existed was session-sticky, so leaving it on silently stopped
      // hiding from applying on the very screen it protects. Un-hiding is
      // Manage's job, and Manage always shows hidden pieces.
      final c = makeContainer();
      await c.read(piecesProvider.future);
      final lib = await library(c);

      await lib.setHidden('b', true);
      expect(c.read(visiblePiecesProvider).value!.map((p) => p.id), ['a', 'c']);

      await lib.setHidden('b', false);
      expect(
          c.read(visiblePiecesProvider).value!.map((p) => p.id), ['a', 'b', 'c']);
    });

    test('a selected collection yields its hand-set order', () async {
      final c = makeContainer();
      await c.read(piecesProvider.future);
      final lib = await library(c);

      final id = await newCollection(c, lib, 'Suzuki 1');
      await lib.setTags('c', {id});
      await lib.setTags('a', {id});

      c.read(activeCollectionProvider.notifier).state = id;
      expect(c.read(visiblePiecesProvider).value!.map((p) => p.id), ['c', 'a']);

      await lib.reorderInCollection(id, ['c', 'a'], 0, 1);
      expect(c.read(visiblePiecesProvider).value!.map((p) => p.id), ['a', 'c']);
    });

    test('a renamed piece shows its new title on both lists', () async {
      final c = makeContainer();
      await c.read(piecesProvider.future);
      final lib = await library(c);

      await lib.renamePiece('b', 'Gavotte');

      expect(c.read(visiblePiecesProvider).value!.map((p) => p.title),
          ['a', 'Gavotte', 'c']);
      expect(c.read(libraryPiecesProvider).value!.map((p) => p.title),
          ['a', 'Gavotte', 'c']);
    });
  });

  test('libraryPiecesProvider keeps hidden pieces, for the Manage screen',
      () async {
    final c = makeContainer();
    await c.read(piecesProvider.future);
    final lib = await library(c);

    await lib.setHidden('b', true);

    expect(c.read(libraryPiecesProvider).value!.map((p) => p.id),
        ['a', 'b', 'c']);
    expect(c.read(visiblePiecesProvider).value!.map((p) => p.id), ['a', 'c']);
  });

  test('the raw list shows while the library read is still in flight',
      () async {
    // Decoration must never gate the library screen behind a spinner.
    final c = makeContainer();
    await c.read(piecesProvider.future);

    expect(c.read(libraryProvider).isLoading, isTrue);
    expect(c.read(visiblePiecesProvider).value!.map((p) => p.id),
        ['a', 'b', 'c']);
  });

  test('the hidden count is scoped to the active collection', () async {
    final c = makeContainer();
    await c.read(piecesProvider.future);
    final lib = await library(c);

    final id = await newCollection(c, lib, 'Suzuki 1');
    await lib.setTags('a', {id});
    await lib.setHidden('a', true);
    await lib.setHidden('b', true);

    expect(c.read(hiddenPieceCountProvider), 2);
    c.read(activeCollectionProvider.notifier).state = id;
    expect(c.read(hiddenPieceCountProvider), 1);
  });

  test('pieceCollectionsProvider derives membership without storing it',
      () async {
    final c = makeContainer();
    await c.read(piecesProvider.future);
    final lib = await library(c);

    final suzuki = await newCollection(c, lib, 'Suzuki 1');
    final week = await newCollection(c, lib, 'This week');
    await lib.setTags('a', {suzuki, week});

    expect(c.read(pieceCollectionsProvider('a')), {suzuki, week});
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
      // Both orientations, since the zoom is stored per orientation — deleting
      // a piece has to take every one of its keys, or the next piece to reuse
      // the id inherits a zoom.
      final zoom = withSaved.read(staffZoomStoreProvider);
      await zoom.save(saved.id, StaffOrientation.portrait, 3);
      await zoom.save(saved.id, StaffOrientation.landscape, 6);

      await withSaved.read(libraryActionsProvider).deletePiece(saved.id);

      final after = withSaved.read(libraryProvider).value!;
      expect(after.collectionById(id)!.pieceIds, isEmpty);
      expect(after.titleOverrides, isEmpty);
      for (final o in StaffOrientation.values) {
        expect(await zoom.load(saved.id, o), isNull, reason: '$o');
      }
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

  test('seeding hides the OMR demo fixtures on first load', () async {
    final c = makeContainer();
    final lib = await c.read(libraryProvider.future);

    expect(lib.hiddenIds, PieceRepository.omrDemoFixtureIds.toSet());
    expect(lib.collections.single.name, omrDemoCollectionName);
    expect(lib.seedVersion, currentSeedVersion);
  });
}

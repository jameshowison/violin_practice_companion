import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_library.dart';

Piece piece(String id, [String? title]) =>
    Piece(id: id, title: title ?? id, musicXmlAssetPath: 'a/$id.xml', sections: const []);

/// A library with one collection holding [ids], plus its id.
({PieceLibrary lib, String id}) withCollection(List<String> ids,
    {String name = 'Suzuki 1'}) {
  var lib = addCollection(PieceLibrary.empty, name: name, nowMillis: 1000);
  final id = lib.collections.single.id;
  for (final p in ids) {
    lib = tagPiece(lib, pieceId: p, collectionId: id);
  }
  return (lib: lib, id: id);
}

void main() {
  group('a library round trips through json', () {
    test('collections, order, hidden ids and title overrides all survive', () {
      final c = withCollection(['a', 'b', 'c']);
      var lib = setHidden(c.lib, 'b', true);
      lib = setTitleOverride(lib, 'a', 'Renamed');
      lib = addCollection(lib, name: 'This week', nowMillis: 2000);

      final restored = PieceLibrary.fromJson(lib.toJson());

      expect(restored, lib);
      expect(restored.collections.map((x) => x.name), ['Suzuki 1', 'This week']);
      expect(restored.collectionById(c.id)!.pieceIds, ['a', 'b', 'c']);
      expect(restored.hiddenIds, {'b'});
      expect(restored.titleOverrides, {'a': 'Renamed'});
    });

    test('an empty document decodes to the empty library', () {
      expect(PieceLibrary.fromJson(const {}), PieceLibrary.empty);
    });

    test('an unrecognised version still decodes what it recognises', () {
      final json = withCollection(['a']).lib.toJson();
      json['version'] = 99;
      json['somethingFromTheFuture'] = {'nope': true};

      final restored = PieceLibrary.fromJson(json);

      expect(restored.collections.single.pieceIds, ['a']);
    });

    test('a malformed collection row is skipped, not thrown on', () {
      // Shaped the way jsonDecode hands it back — List<dynamic>, not the
      // statically-typed list toJson() builds.
      final restored = PieceLibrary.fromJson(<String, dynamic>{
        'version': 1,
        'collections': <dynamic>[
          'not a map',
          {'name': 'no id'},
          {'id': 'suzuki_1_1000', 'name': 'Suzuki 1', 'pieceIds': ['a']},
          {'id': 'ok_1', 'name': 'Kept', 'pieceIds': 'not a list'},
        ],
      });

      // A corrupt library loses chips, not songs.
      expect(restored.collections.map((c) => c.name), ['Suzuki 1', 'Kept']);
      expect(restored.collections.last.pieceIds, isEmpty);
    });

    test('garbage in the hidden and titles slots is ignored', () {
      final restored = PieceLibrary.fromJson({
        'hidden': 'not a list',
        'titles': ['not a map'],
        'seedVersion': 'not an int',
      });

      expect(restored, PieceLibrary.empty);
    });
  });

  group('membership and order are one structure', () {
    test('tagging appends at the end and is idempotent', () {
      final c = withCollection(['a', 'b']);
      final twice = tagPiece(c.lib, pieceId: 'a', collectionId: c.id);

      expect(twice.collectionById(c.id)!.pieceIds, ['a', 'b']);
      expect(twice, c.lib);
    });

    test('untagging removes membership and its slot in one move', () {
      final c = withCollection(['a', 'b', 'c']);
      final after = untagPiece(c.lib, pieceId: 'b', collectionId: c.id);

      expect(after.collectionById(c.id)!.pieceIds, ['a', 'c']);
    });

    test('setPieceTags preserves position in collections the piece stays in',
        () {
      // The regression a naive clear-and-re-add would cause: opening the tag
      // dialog and pressing Save without changing anything would silently send
      // every re-checked piece to the bottom of its collection.
      final c = withCollection(['a', 'b', 'c']);
      var lib = addCollection(c.lib, name: 'This week', nowMillis: 2000);
      final weekId = lib.collections.last.id;

      lib = setPieceTags(lib, pieceId: 'a', collectionIds: {c.id, weekId});

      expect(lib.collectionById(c.id)!.pieceIds, ['a', 'b', 'c'],
          reason: 'a was already first and did not move');
      expect(lib.collectionById(weekId)!.pieceIds, ['a']);
    });

    test('setPieceTags removes from unchecked collections', () {
      final c = withCollection(['a', 'b']);
      final after = setPieceTags(c.lib, pieceId: 'a', collectionIds: const {});

      expect(after.collectionById(c.id)!.pieceIds, ['b']);
    });
  });

  group('reordering within a collection', () {
    test('a downward move lands at the destination index', () {
      // newIndex is the FINAL position, as onReorderItem reports it.
      expect(reorderedIds(['a', 'b', 'c'], 0, 1), ['b', 'a', 'c']);
      expect(reorderedIds(['a', 'b', 'c'], 0, 2), ['b', 'c', 'a']);
    });

    test('an upward move lands at the destination index', () {
      expect(reorderedIds(['a', 'b', 'c'], 2, 0), ['c', 'a', 'b']);
      expect(reorderedIds(['a', 'b', 'c'], 1, 0), ['b', 'a', 'c']);
    });

    test('an out-of-range destination is clamped, not thrown on', () {
      expect(reorderedIds(['a', 'b', 'c'], 0, 9), ['b', 'c', 'a']);
      expect(reorderedIds(['a', 'b', 'c'], 9, 0), ['a', 'b', 'c']);
    });

    test('a no-op drag returns the same list', () {
      final ids = ['a', 'b', 'c'];
      expect(identical(reorderedIds(ids, 1, 1), ids), isTrue);
    });

    test('reordering one collection does not touch another sharing the piece',
        () {
      final c = withCollection(['a', 'b', 'c']);
      var lib = addCollection(c.lib, name: 'This week', nowMillis: 2000);
      final weekId = lib.collections.last.id;
      for (final p in ['a', 'b']) {
        lib = tagPiece(lib, pieceId: p, collectionId: weekId);
      }

      lib = reorderInCollection(lib, c.id, ['a', 'b', 'c'], 0, 2);

      expect(lib.collectionById(c.id)!.pieceIds, ['b', 'c', 'a']);
      expect(lib.collectionById(weekId)!.pieceIds, ['a', 'b']);
    });

    test('members not on screen keep their stored slots', () {
      // 'b' is hidden, so the user drags a 2-row list; 'b' must not move.
      final c = withCollection(['a', 'b', 'c']);
      final lib = reorderInCollection(c.lib, c.id, ['a', 'c'], 0, 1);

      expect(lib.collectionById(c.id)!.pieceIds, ['c', 'b', 'a']);
    });
  });

  group('renaming a collection', () {
    test('keeps the id and the membership, so an active filter survives', () {
      final c = withCollection(['a', 'b']);
      final after = renameCollection(c.lib, c.id, 'Book 1');

      expect(after.collections.single.id, c.id);
      expect(after.collections.single.name, 'Book 1');
      expect(after.collections.single.pieceIds, ['a', 'b']);
    });

    test('a blank name is refused', () {
      final c = withCollection(['a']);
      expect(renameCollection(c.lib, c.id, '   '), c.lib);
    });

    test('two collections may share a name without colliding', () {
      var lib = addCollection(PieceLibrary.empty, name: 'Scales', nowMillis: 7);
      lib = addCollection(lib, name: 'Scales', nowMillis: 7);

      expect(lib.collections, hasLength(2));
      expect(lib.collections[0].id, isNot(lib.collections[1].id));
    });

    test('deleting a collection removes the label, never the pieces', () {
      final c = withCollection(['a', 'b']);
      final after = removeCollection(c.lib, c.id);

      expect(after.collections, isEmpty);
      expect(applyLibrary(after, [piece('a'), piece('b')]), hasLength(2));
    });
  });

  group('forgetting a piece', () {
    test('drops it from every collection, hidden and overrides at once', () {
      final c = withCollection(['a', 'b', 'c']);
      var lib = addCollection(c.lib, name: 'This week', nowMillis: 2000);
      lib = tagPiece(lib, pieceId: 'b', collectionId: lib.collections.last.id);
      lib = setHidden(lib, 'b', true);
      lib = setTitleOverride(lib, 'b', 'Renamed');

      lib = forgetPiece(lib, 'b');

      expect(lib.collections[0].pieceIds, ['a', 'c']);
      expect(lib.collections[1].pieceIds, isEmpty);
      expect(lib.hiddenIds, isEmpty);
      expect(lib.titleOverrides, isEmpty);
    });
  });

  group('stale ids are inert', () {
    test('pruneToExisting drops unknown ids and keeps the rest in order', () {
      final c = withCollection(['a', 'gone', 'b']);
      var lib = setHidden(c.lib, 'gone', true);
      lib = setTitleOverride(lib, 'gone', 'Ghost');

      lib = pruneToExisting(lib, {'a', 'b'});

      expect(lib.collectionById(c.id)!.pieceIds, ['a', 'b']);
      expect(lib.hiddenIds, isEmpty);
      expect(lib.titleOverrides, isEmpty);
    });

    test('pruning nothing returns the identical instance', () {
      final c = withCollection(['a', 'b']);
      expect(identical(pruneToExisting(c.lib, {'a', 'b'}), c.lib), isTrue);
    });

    test('an unpruned stale id is skipped by applyLibrary, not thrown on', () {
      final c = withCollection(['a', 'gone', 'b']);
      final shown = applyLibrary(c.lib, [piece('a'), piece('b')],
          collectionId: c.id);

      expect(shown.map((p) => p.id), ['a', 'b']);
    });
  });

  group('applyLibrary', () {
    final all = [piece('a'), piece('b'), piece('c')];

    test('with no collection the input order is returned untouched', () {
      final c = withCollection(['c', 'a']);
      expect(applyLibrary(c.lib, all).map((p) => p.id), ['a', 'b', 'c']);
    });

    test('with a collection, exactly its members in its hand-set order', () {
      final c = withCollection(['c', 'a']);
      expect(applyLibrary(c.lib, all, collectionId: c.id).map((p) => p.id),
          ['c', 'a']);
    });

    test('hidden pieces are dropped', () {
      final lib = setHidden(PieceLibrary.empty, 'b', true);
      expect(applyLibrary(lib, all).map((p) => p.id), ['a', 'c']);
    });

    test('hidden pieces are dropped inside a collection too', () {
      // Otherwise "hidden" would mean different things on different chips.
      final c = withCollection(['a', 'b', 'c']);
      final lib = setHidden(c.lib, 'b', true);
      expect(applyLibrary(lib, all, collectionId: c.id).map((p) => p.id),
          ['a', 'c']);
    });

    test('showHidden puts them back in place', () {
      final c = withCollection(['a', 'b', 'c']);
      final lib = setHidden(c.lib, 'b', true);
      expect(
          applyLibrary(lib, all, collectionId: c.id, showHidden: true)
              .map((p) => p.id),
          ['a', 'b', 'c']);
    });

    test('a title override wins over the score title', () {
      final lib = setTitleOverride(PieceLibrary.empty, 'b', 'Gavotte');
      expect(applyLibrary(lib, all).map((p) => p.title), ['a', 'Gavotte', 'c']);
    });

    test('clearing an override reverts to the score title', () {
      var lib = setTitleOverride(PieceLibrary.empty, 'b', 'Gavotte');
      lib = setTitleOverride(lib, 'b', null);
      expect(applyLibrary(lib, all).map((p) => p.title), ['a', 'b', 'c']);
    });

    test('an un-overridden piece comes back as the same instance', () {
      // Identity comparison drives re-engraving downstream, so applyLibrary
      // must not hand out fresh Piece objects it did not need to make.
      final lib = setTitleOverride(PieceLibrary.empty, 'b', 'Gavotte');
      final shown = applyLibrary(lib, all);
      expect(identical(shown[0], all[0]), isTrue);
      expect(identical(shown[1], all[1]), isFalse);
    });

    test('an override for a piece that no longer exists is inert', () {
      final lib = setTitleOverride(PieceLibrary.empty, 'gone', 'Ghost');
      expect(applyLibrary(lib, all).map((p) => p.title), ['a', 'b', 'c']);
    });

    test('an unknown collection id yields nothing', () {
      expect(applyLibrary(PieceLibrary.empty, all, collectionId: 'nope'),
          isEmpty);
    });
  });

  group('the hidden count', () {
    final all = [piece('a'), piece('b'), piece('c')];

    test('counts every hidden piece when no collection is active', () {
      var lib = setHidden(PieceLibrary.empty, 'a', true);
      lib = setHidden(lib, 'b', true);
      expect(hiddenCount(lib, all), 2);
    });

    test('is scoped to the active collection', () {
      // The footer must not promise pieces that showing hidden wouldn't reveal.
      final c = withCollection(['a']);
      var lib = setHidden(c.lib, 'a', true);
      lib = setHidden(lib, 'b', true);

      expect(hiddenCount(lib, all, collectionId: c.id), 1);
    });
  });

  group('seeding runs exactly once', () {
    const demos = ['abc_01', 'homr_01', 'abc_02'];

    test('the first run hides the demos and files them together', () {
      final lib =
          seedLibrary(PieceLibrary.empty, omrDemoIds: demos, nowMillis: 500);

      expect(lib.hiddenIds, demos.toSet());
      expect(lib.collections.single.name, omrDemoCollectionName);
      expect(lib.collections.single.pieceIds, demos);
      expect(lib.seedVersion, currentSeedVersion);
    });

    test('a second run changes nothing', () {
      final once =
          seedLibrary(PieceLibrary.empty, omrDemoIds: demos, nowMillis: 500);
      final twice = seedLibrary(once, omrDemoIds: demos, nowMillis: 900);

      expect(twice, once);
    });

    test('un-hiding a demo survives a later seed run', () {
      var lib =
          seedLibrary(PieceLibrary.empty, omrDemoIds: demos, nowMillis: 500);
      lib = setHidden(lib, 'homr_01', false);

      lib = seedLibrary(lib, omrDemoIds: demos, nowMillis: 900);

      expect(lib.hiddenIds, {'abc_01', 'abc_02'});
    });

    test('a library with no demos to seed still records the version', () {
      final lib = seedLibrary(PieceLibrary.empty,
          omrDemoIds: const [], nowMillis: 500);

      expect(lib.collections, isEmpty);
      expect(lib.seedVersion, currentSeedVersion);
    });
  });
}

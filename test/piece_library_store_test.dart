import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece_library.dart';
import 'package:violin_practice_companion/services/piece_library_store.dart';

void main() {
  late PieceLibraryStore store;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    store = PieceLibraryStore();
  });

  PieceLibrary sample() {
    var lib = addCollection(PieceLibrary.empty, name: 'Suzuki 1', nowMillis: 1);
    final id = lib.collections.single.id;
    for (final p in ['c', 'a', 'b']) {
      lib = tagPiece(lib, pieceId: p, collectionId: id);
    }
    lib = setHidden(lib, 'b', true);
    lib = setTitleOverride(lib, 'a', 'Gavotte');
    return lib.copyWith(seedVersion: currentSeedVersion);
  }

  test('an absent key loads as the empty library', () async {
    expect(await store.load(), PieceLibrary.empty);
  });

  test('save then load round trips everything, order included', () async {
    final lib = sample();

    await store.save(lib);

    final restored = await store.load();
    expect(restored, lib);
    expect(restored.collections.single.pieceIds, ['c', 'a', 'b']);
    expect(restored.hiddenIds, {'b'});
    expect(restored.titleOverrides, {'a': 'Gavotte'});
    expect(restored.seedVersion, currentSeedVersion);
  });

  test('a corrupt blob loses chips, not songs', () async {
    // The library must never be able to take the piece list down with it.
    for (final garbage in ['', '   ', 'not json at all', '[1,2,3]', '"a string"']) {
      SharedPreferences.setMockInitialValues({'pieceLibrary': garbage});
      expect(await PieceLibraryStore().load(), PieceLibrary.empty,
          reason: 'blob "$garbage"');
    }
  });

  test('saving writes exactly one key and collides with nothing else', () async {
    // The prefs store is shared with `measuresPerLine.<id>` (StaffZoomStore)
    // and, on web, with every `piece.<id>.*` key.
    SharedPreferences.setMockInitialValues({
      'measuresPerLine.lightly_row': 3,
      'piece.old_joe_1.xml': '<score/>',
    });
    final freshStore = PieceLibraryStore();

    await freshStore.save(sample());

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {
      'measuresPerLine.lightly_row',
      'piece.old_joe_1.xml',
      'pieceLibrary',
    });
    expect(prefs.getInt('measuresPerLine.lightly_row'), 3);
  });

  test('saving the empty library is readable back as empty', () async {
    await store.save(PieceLibrary.empty);
    expect(await store.load(), PieceLibrary.empty);
  });
}

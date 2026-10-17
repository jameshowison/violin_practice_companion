import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/services/dev_library_bundle.dart';

/// The web half of the dev library: the same three-way table as
/// dev_library_test.dart, over prefs keys instead of files.
void main() {
  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  Map<String, dynamic> bundle(Map<String, String> prefs) =>
      {'version': 1, 'prefs': prefs};

  test('a fresh browser takes everything, seed library included', () async {
    final prefs = await prefsWith({'pieceLibrary': '{"collections":[]}'});
    await DevLibraryBundleMerger(prefs).merge(bundle({
      'piece.a.xml': '<a/>',
      'piece.a.title': 'A',
      'pieceLibrary': '{"collections": [{"id": "c"}]}',
    }));
    expect(prefs.getString('piece.a.xml'), '<a/>');
    expect(prefs.getString('piece.a.title'), 'A');
    expect(prefs.getString('pieceLibrary'), contains('"c"'));
  });

  test('library edits and deletions apply; browser-only pieces stay', () async {
    final prefs = await prefsWith({'piece.mine.xml': '<m/>'});
    final m = DevLibraryBundleMerger(prefs);
    await m.merge(bundle({'piece.a.xml': '<a/>', 'piece.b.xml': '<b/>'}));
    await m.merge(bundle({'piece.a.xml': '<a2/>'}));
    expect(prefs.getString('piece.a.xml'), '<a2/>');
    expect(prefs.containsKey('piece.b.xml'), isFalse);
    expect(prefs.getString('piece.mine.xml'), '<m/>');
  });

  test('a browser edit is kept, and a conflict keeps the browser', () async {
    final prefs = await prefsWith({});
    final m = DevLibraryBundleMerger(prefs);
    await m.merge(bundle({'piece.a.xml': '<a/>', 'piece.b.xml': '<b/>'}));
    await prefs.setString('piece.a.xml', '<mine/>');
    await prefs.setString('piece.b.xml', '<mine-b/>');
    final report = await m.merge(
        bundle({'piece.a.xml': '<a/>', 'piece.b.xml': '<b2/>'}));
    expect(prefs.getString('piece.a.xml'), '<mine/>');
    expect(prefs.getString('piece.b.xml'), '<mine-b/>');
    expect(report, contains('CONFLICTS'));
    expect(report, contains('piece.b.xml'));
  });

  test('re-encoded JSON is not a local change', () async {
    final prefs = await prefsWith({});
    final m = DevLibraryBundleMerger(prefs);
    await m.merge(bundle({'sections.a': '{"sections": [{"label": "A"}]}'}));
    await prefs.setString('sections.a', '{"sections":[{"label":"A"}]}');
    await m.merge(bundle({'sections.a': '{"sections": [{"label": "B"}]}'}));
    expect(prefs.getString('sections.a'), contains('"B"'));
  });
}

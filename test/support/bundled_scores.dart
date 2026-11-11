// The scores the suite iterates over, read off disk (not rootBundle), so plain
// `dart:io` tests see exactly what the app bundles.
import 'dart:convert';
import 'dart:io';

/// `assets/library/<id>/score.musicxml` for every piece in the catalog.
List<File> bundledScoreFiles() {
  final catalog = json.decode(File('assets/library/catalog.json').readAsStringSync())
      as Map<String, dynamic>;
  return [
    for (final p in catalog['pieces'] as List)
      File('assets/library/${(p as Map<String, dynamic>)['score']}'),
  ]..sort((a, b) => a.path.compareTo(b.path));
}

/// The OMR readings kept as test data (`test/fixtures/omr/*.xml`).
List<File> omrFixtureFiles() => Directory('test/fixtures/omr')
    .listSync()
    .whereType<File>()
    .where((f) => f.path.endsWith('.xml'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

/// Everything the "every fixture round-trips" tests used to find in
/// `assets/fixtures/` before the library and the OMR set were split.
List<File> allScoreFixtures() => [...bundledScoreFiles(), ...omrFixtureFiles()];

/// A bundled piece's score / sections, by piece id.
String scorePath(String id) => 'assets/library/$id/score.musicxml';
String sectionsPath(String id) => 'assets/library/$id/sections.json';

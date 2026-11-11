// What ships with the app is exactly what assets/library/catalog.json lists,
// and every listed item says where it comes from and under what licence.
//
// This is the guard behind CONTRIBUTING.md, "Content and copyright": a score
// dropped into the library without a catalog entry, an entry without a source,
// a Suzuki-edition title or an edition's fingerings riding along in a bundled
// file all fail here, on every `flutter test`.
//
// VPC_PUBLIC_RELEASE=1 additionally refuses anything licensed
// `internal-testing-only` (fine for a TestFlight build for known testers, not
// for a public release).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece_catalog.dart';

void main() {
  final catalog = PieceCatalog.fromJson(
      json.decode(File(kCatalogAsset).readAsStringSync()) as Map<String, dynamic>);

  group('catalog', () {
    test('ids are unique', () {
      final ids = [for (final p in catalog.pieces) p.id];
      expect(ids.toSet().length, ids.length);
    });

    for (final p in catalog.pieces) {
      test('${p.id}: files exist and provenance is filled in', () {
        expect(File(p.scoreAsset).existsSync(), isTrue, reason: p.scoreAsset);
        expect(File(p.sectionsAsset).existsSync(), isTrue,
            reason: p.sectionsAsset);
        expect(p.title.trim(), isNotEmpty);
        expect(p.composer.trim(), isNotEmpty);
        expect(p.source.trim(), isNotEmpty, reason: 'say where it comes from');
        expect(CatalogLicense.all, contains(p.license));
        expect(const {'app', 'cleared'}, contains(p.fingerings));
        // A piece's files live in its own folder, so removing it is one rm -r.
        expect(p.score, startsWith('${p.id}/'));
        expect(p.sections, startsWith('${p.id}/'));
      });
    }

    for (final a in catalog.allAudio) {
      test('audio ${a.folder}: provenance is filled in', () {
        expect(a.source.trim(), isNotEmpty);
        expect(CatalogLicense.all, contains(a.license));
      });
    }
  });

  group('bundle', () {
    test('assets/ holds only engine/ and library/', () {
      final top = Directory('assets')
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .where((n) => !n.startsWith('.'))
          .toSet();
      expect(top, {'engine', 'library'});
    });

    test('every file in assets/library/ is one the catalog lists', () {
      final scores = {for (final p in catalog.pieces) p.scoreAsset};
      final sections = {for (final p in catalog.pieces) p.sectionsAsset};
      final audioDirs = {
        for (final a in catalog.allAudio) '${bundledAudioDir(a.folder)}/'
      };
      final strays = <String>[];
      for (final f in Directory(kLibraryAssetDir)
          .listSync(recursive: true)
          .whereType<File>()) {
        final path = f.path;
        if (path.split('/').last.startsWith('.')) continue;
        if (path == kCatalogAsset ||
            scores.contains(path) ||
            sections.contains(path) ||
            audioDirs.any(path.startsWith)) {
          continue;
        }
        strays.add(path);
      }
      expect(strays, isEmpty,
          reason: 'add these to catalog.json (with source and licence) '
              'or move them out of assets/library/');
    });

    test('pubspec bundles exactly the catalog\'s folders', () {
      final listed = {
        for (final line in File('pubspec.yaml').readAsLinesSync())
          if (RegExp(r'^\s+- assets/library/').hasMatch(line))
            line.trim().substring(2).trim(),
      };
      final want = {
        '$kLibraryAssetDir/',
        for (final p in catalog.pieces) '$kLibraryAssetDir/${p.id}/',
        for (final a in catalog.allAudio) '${bundledAudioDir(a.folder)}/',
      };
      expect(listed, want);
    });
  });

  group('scores carry only the music', () {
    for (final p in catalog.pieces) {
      test(p.id, () {
        final xml = File(p.scoreAsset).readAsStringSync();
        expect(xml.toLowerCase(), isNot(contains('suzuki')),
            reason: 'no edition names or trademarks in bundled content');
        expect(p.title.toLowerCase(), isNot(contains('suzuki')));
        // Title pages and encoder provenance belong to an edition, not the
        // tune; scripts/clean_musicxml.py removes them.
        expect(xml, isNot(contains('<credit')));
        expect(xml, isNot(contains('<source>')));
        expect(xml, isNot(contains('<rights>')));
        if (p.fingerings == 'app') {
          expect(xml, isNot(contains('<fingering')),
              reason: 'fingerings are app-generated; clean the score');
          expect(xml, isNot(contains('<up-bow')));
          expect(xml, isNot(contains('<down-bow')));
        }
      });
    }
  });

  test(
    'a public release ships nothing internal-testing-only',
    skip: Platform.environment['VPC_PUBLIC_RELEASE'] == '1'
        ? null
        : 'set VPC_PUBLIC_RELEASE=1 before a public release',
    () {
      final internal = [
        for (final p in catalog.pieces)
          if (!CatalogLicense.publicRelease.contains(p.license)) p.id,
        for (final a in catalog.allAudio)
          if (!CatalogLicense.publicRelease.contains(a.license))
            'audio ${a.folder}',
      ];
      expect(internal, isEmpty);
    },
  );
}

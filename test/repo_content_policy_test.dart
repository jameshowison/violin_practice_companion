// What may be committed to this public repo at all (CONTRIBUTING.md, "Content
// and copyright"). Deliberately generic — it names kinds of file and where they
// may live, never specific works — so the rule can be public.
//
// Scans and photos of printed music, recordings and downloaded scores are the
// things that have gone wrong before. Their home is the maintainer's private
// companion repo; tests reach them through test/support/restricted_fixtures.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Images, documents, audio, video and model files: allowed only here.
const _mediaAllowed = <String>[
  'android/app/src/main/res/', // launcher icons
  'ios/Runner/Assets.xcassets/',
  'macos/Runner/Assets.xcassets/',
  'windows/runner/resources/',
  'web/icons/',
  'web/favicon.png',
  'docs/images/', // screenshots of the app itself
];

/// Engraved output of the project's own public scores, used as test input.
final _engravingFixture = RegExp(r'^test/fixtures/verovio_[a-z_]+\.svg$');

final _media = RegExp(
    r'\.(png|jpe?g|gif|heic|webp|tiff?|bmp|pdf|mp3|wav|m4a|aac|flac|ogg|aiff?|'
    r'mp4|mov|m4v|webm|sf2|sf3|onnx|svg|ico|icns)$',
    caseSensitive: false);

/// Score files: allowed only in the bundled library, test fixtures, and the
/// ABC sources / OMR-evaluation outputs in docs/.
const _scoresAllowed = <String>[
  'assets/library/',
  'test/fixtures/',
  'docs/',
];
final _scoreExt =
    RegExp(r'\.(musicxml|mxl|mscz|mscx|abc|ly|mei)$', caseSensitive: false);

/// Local-only folders that must never be committed.
const _neverCommitted = <String>[
  'lyrics_eval/',
  'docs/photos_no_share/',
  'scan_sources/',
];

void main() {
  final ls = Process.runSync('git', ['ls-files', '-z']);
  final files = ls.exitCode == 0
      ? (ls.stdout as String).split('\x00').where((f) => f.isNotEmpty).toList()
      : <String>[];
  final skip = files.isEmpty ? 'not a git checkout' : null;

  test('images, documents, audio and models only where allowed', skip: skip,
      () {
    final bad = [
      for (final f in files)
        if (_media.hasMatch(f) &&
            !_mediaAllowed.any(f.startsWith) &&
            !_engravingFixture.hasMatch(f))
          f,
    ];
    expect(bad, isEmpty,
        reason: 'scans, photos, recordings and PDFs of published material go '
            'in the private companion repo, not here');
  });

  test('score files only in the library, test fixtures and docs', skip: skip,
      () {
    bool isScore(String f) {
      if (_scoreExt.hasMatch(f)) return true;
      if (!f.endsWith('.xml')) return false;
      final head = File(f).openSync();
      try {
        final s = String.fromCharCodes(head.readSync(2048));
        return s.contains('<score-partwise') || s.contains('<score-timewise');
      } finally {
        head.closeSync();
      }
    }

    final bad = [
      for (final f in files)
        if (!_scoresAllowed.any(f.startsWith) &&
            File(f).existsSync() &&
            isScore(f))
          f,
    ];
    expect(bad, isEmpty);
  });

  test('local-only folders are never committed', skip: skip, () {
    final bad = [
      for (final f in files)
        if (_neverCommitted.any(f.startsWith)) f,
    ];
    expect(bad, isEmpty);
  });
}

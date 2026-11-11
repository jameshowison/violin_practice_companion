// Fixtures that may be under copyright live outside this public repo, in the
// maintainer's private companion checkout (see CONTRIBUTING.md, "Content and
// copyright"). Tests that need one ask for it here and skip when it's absent,
// so a fresh public clone runs the suite green.
//
// Looks in $VPC_RESTRICTED_DIR, else ../violin_practice_restricted.
import 'dart:io';

/// Root of the private companion checkout, or null if there isn't one.
Directory? restrictedDir() {
  final env = Platform.environment['VPC_RESTRICTED_DIR'];
  final dir = Directory(env ?? '../violin_practice_restricted');
  return dir.existsSync() ? dir : null;
}

/// `<restricted>/<relativePath>` if it exists, else null.
File? restrictedFile(String relativePath) {
  final root = restrictedDir();
  if (root == null) return null;
  final f = File('${root.path}/$relativePath');
  return f.existsSync() ? f : null;
}

/// The `skip:` value for a test that needs [relativePath]: null to run it, a
/// reason string to skip it.
String? skipUnlessRestricted(String relativePath) =>
    restrictedFile(relativePath) == null
        ? 'needs $relativePath from the private companion repo '
            '(set VPC_RESTRICTED_DIR)'
        : null;

/// The file's contents. Only call from a test guarded by
/// [skipUnlessRestricted]; throws if it is missing.
String readRestricted(String relativePath) {
  final f = restrictedFile(relativePath);
  if (f == null) throw StateError('missing restricted fixture $relativePath');
  return f.readAsStringSync();
}

// The restricted fixtures the suite uses, relative to the companion checkout.
const kGundagaiLyrics = 'fixtures/lyrics/gundagai_lyrics.musicxml';
const kGundagaiScan = 'fixtures/lyrics/gundagai_scan.musicxml';
const kVerovioVerseSvg = 'fixtures/svg/verovio_verse.svg';

/// Platform-independent pieces of the piece store, shared by
/// `piece_storage_io.dart` and `piece_storage_web.dart` so the two can't drift.
///
/// Follows the same `*_base.dart` convention as `abc_converter_base.dart` and
/// `playback_service_base.dart`.
library;

/// A stored piece's stable identity: a slug of its title plus the creation
/// timestamp in milliseconds.
///
/// This is the ONLY durable name a piece has. Both backends derive their storage
/// location from it (`<id>.musicxml` on disk, `piece.<id>.xml` in web storage),
/// which is what makes the piece index a rebuildable cache: given the id you can
/// always find the content again, and given the content you can always find the
/// id. Nothing derived from a filesystem location is ever persisted — that was
/// the bug this design replaces (an absolute container path in `index.json` went
/// stale on every reinstall).
String scannedPieceId(String title, {required int createdAtMillis}) =>
    '${slugifyTitle(title)}_$createdAtMillis';

/// The creation timestamp embedded in an [scannedPieceId], or null if the id
/// doesn't carry one. Lets a backend with no insertion order of its own (web)
/// still list pieces oldest-first.
int? createdAtMillisOf(String id) {
  final underscore = id.lastIndexOf('_');
  if (underscore < 0) return null;
  return int.tryParse(id.substring(underscore + 1));
}

/// Lowercased, `_`-separated, ASCII-only form of [title]; `untitled` when that
/// leaves nothing. Kept deliberately conservative so an id is safe as both a
/// filename and a storage key.
String slugifyTitle(String title) {
  final slug = title
      .toLowerCase()
      .trim()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'untitled' : slug;
}

/// Orders pieces oldest-first by the timestamp in their ids, falling back to id
/// order for anything without one.
int compareByCreatedAt(String idA, String idB) {
  final a = createdAtMillisOf(idA);
  final b = createdAtMillisOf(idB);
  if (a != null && b != null) return a.compareTo(b);
  return idA.compareTo(idB);
}

import 'package:shared_preferences/shared_preferences.dart';

/// Per-piece persistence for the staff zoom (measures-per-line) override.
///
/// A view preference, not musical content, so it deliberately does NOT live on
/// the [Piece] model or go through [PieceRepository]: that storage layer is
/// `dart:io`-only (`piece_storage_web.dart` throws `UnsupportedError`), and web
/// is the current shipping target. `shared_preferences` covers
/// iOS/Android/macOS/Web from one API, so no conditional-import split is needed.
///
/// Absent key ⇒ null ⇒ auto (see `autoMeasuresPerLine` in `staff_zoom.dart`).
class StaffZoomStore {
  static const _prefix = 'measuresPerLine.';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _open() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// The stored override for [pieceId], or null when the piece is on auto.
  /// Never throws — a preferences failure just means "no override".
  Future<int?> load(String pieceId) async {
    try {
      return (await _open()).getInt('$_prefix$pieceId');
    } catch (_) {
      return null;
    }
  }

  /// Persists [measuresPerLine] for [pieceId]; a null value clears the override
  /// (back to auto). Best-effort — a write failure must never break the UI.
  Future<void> save(String pieceId, int? measuresPerLine) async {
    try {
      final prefs = await _open();
      if (measuresPerLine == null) {
        await prefs.remove('$_prefix$pieceId');
      } else {
        await prefs.setInt('$_prefix$pieceId', measuresPerLine);
      }
    } catch (_) {
      // Ignore: the session-level provider still holds the value.
    }
  }

  /// Forgets [pieceId] entirely — part of deleting a piece, so its preference
  /// doesn't outlive it and get inherited by a later piece with the same id.
  Future<void> clear(String pieceId) => save(pieceId, null);
}

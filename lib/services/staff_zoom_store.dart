import 'package:shared_preferences/shared_preferences.dart';

import 'staff_zoom.dart' show StaffOrientation;

/// Per-piece, per-orientation persistence for the staff zoom (measures-per-line)
/// override.
///
/// A view preference, not musical content, so it deliberately does NOT live on
/// the [Piece] model or go through [PieceRepository]: that storage layer is
/// `dart:io`-only (`piece_storage_web.dart` throws `UnsupportedError`), and web
/// is the current shipping target. `shared_preferences` covers
/// iOS/Android/macOS/Web from one API, so no conditional-import split is needed.
///
/// Absent key ⇒ null ⇒ auto (see `autoMeasuresPerLine` in `staff_zoom.dart`).
///
/// ## Why the key carries the orientation
///
/// Measures-per-line means a different note size in each orientation — a phone
/// in landscape is nearly twice as wide, and the score is engraved to the full
/// width either way. A single stored value therefore cannot serve both: setting
/// a comfortable zoom in portrait guarantees the wrong one on rotation.
///
/// ## The legacy key
///
/// Before the split, the key was just `measuresPerLine.<pieceId>`. Those values
/// are honoured rather than discarded: [load] falls back to the legacy key, so
/// both orientations start out reading whatever was set before, and they diverge
/// the first time either one is written.
///
/// That fallback is also why [save] has to actively **retire** the legacy key
/// (see [_retireLegacy]) instead of just writing the new one. Otherwise clearing
/// an orientation back to auto could never stick: the `remove` would succeed and
/// the next [load] would fall straight back through to the legacy value.
class StaffZoomStore {
  static const _prefix = 'measuresPerLine.';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _open() async =>
      _prefs ??= await SharedPreferences.getInstance();

  String _legacyKey(String pieceId) => '$_prefix$pieceId';

  String _key(String pieceId, StaffOrientation orientation) =>
      '$_prefix$pieceId.${orientation.name}';

  /// The stored override for [pieceId] in [orientation], or null when that
  /// orientation is on auto. Never throws — a preferences failure just means
  /// "no override".
  Future<int?> load(String pieceId, StaffOrientation orientation) async {
    try {
      final prefs = await _open();
      return prefs.getInt(_key(pieceId, orientation)) ??
          prefs.getInt(_legacyKey(pieceId));
    } catch (_) {
      return null;
    }
  }

  /// Persists [measuresPerLine] for [pieceId] in [orientation]; a null value
  /// clears that orientation's override (back to auto), leaving the other
  /// orientation alone. Best-effort — a write failure must never break the UI.
  Future<void> save(
    String pieceId,
    StaffOrientation orientation,
    int? measuresPerLine,
  ) async {
    try {
      final prefs = await _open();
      await _retireLegacy(prefs, pieceId, keepFor: orientation.other);
      final key = _key(pieceId, orientation);
      if (measuresPerLine == null) {
        await prefs.remove(key);
      } else {
        await prefs.setInt(key, measuresPerLine);
      }
    } catch (_) {
      // Ignore: the session-level provider still holds the value.
    }
  }

  /// Promotes any pre-split value into [keepFor] and deletes it.
  ///
  /// Called on the first write for a piece, and a no-op after that. Promoting
  /// rather than simply deleting is what keeps the *other* orientation on the
  /// value the user had already chosen — this write only speaks for the
  /// orientation being written.
  Future<void> _retireLegacy(
    SharedPreferences prefs,
    String pieceId, {
    required StaffOrientation keepFor,
  }) async {
    final legacy = prefs.getInt(_legacyKey(pieceId));
    if (legacy == null) return;
    final key = _key(pieceId, keepFor);
    if (prefs.getInt(key) == null) await prefs.setInt(key, legacy);
    await prefs.remove(_legacyKey(pieceId));
  }

  /// Forgets [pieceId] entirely — both orientations and any pre-split value.
  /// Part of deleting a piece, so its preference doesn't outlive it and get
  /// inherited by a later piece with the same id.
  Future<void> clear(String pieceId) async {
    try {
      final prefs = await _open();
      for (final orientation in StaffOrientation.values) {
        await prefs.remove(_key(pieceId, orientation));
      }
      await prefs.remove(_legacyKey(pieceId));
    } catch (_) {
      // Ignore: best-effort, same as save.
    }
  }
}

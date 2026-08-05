import 'package:shared_preferences/shared_preferences.dart';

/// Persistence for the count-in length.
///
/// One key for the whole app, not per piece: how long you need to get the
/// instrument up is a fact about the player, not about the tune. Same reasoning
/// (and same `shared_preferences` reasoning) as [StaffZoomStore], which is
/// per-piece only because zoom depends on how dense that particular score is.
///
/// Absent key ⇒ null ⇒ auto (one bar, floored — see `countInBeats`). A stored 0
/// means the user turned the count-in off, which is why absent and 0 have to
/// stay tellable apart.
class CountInStore {
  static const _key = 'countInBeats';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _open() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// The stored beat count, or null for auto. Never throws — a preferences
  /// failure just means "no preference".
  Future<int?> load() async {
    try {
      return (await _open()).getInt(_key);
    } catch (_) {
      return null;
    }
  }

  /// Persists [beats]; null clears the setting (back to auto). Best-effort — a
  /// write failure must never break the UI, the session still holds the value.
  Future<void> save(int? beats) async {
    try {
      final prefs = await _open();
      if (beats == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setInt(_key, beats);
      }
    } catch (_) {
      // Ignore: the session-level provider still holds the value.
    }
  }
}

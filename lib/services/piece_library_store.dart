import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/piece_library.dart';

/// Persistence for the piece library: collections and their order, hidden ids,
/// and title overrides.
///
/// One JSON blob under one key, on `shared_preferences` — the same choice as
/// [StaffZoomStore], and for the same reason: this is metadata ABOUT pieces,
/// not piece content, and it must survive on web where there is no filesystem.
///
/// Routing it through the `piece_storage_io`/`piece_storage_web` split was
/// rejected. Those backends are per-piece content stores keyed by id; a library
/// blob is a different shape. More decisively, the two arms would be
/// semantically identical — a conditional-import split with no platform
/// difference to hide is the smell, not the fix — and it would double the
/// surface that split keeps in sync by convention.
///
/// Only piece IDs are stored: no paths, no titles-as-keys, no list positions.
/// See `piece_storage_io.dart` for why anything location-derived is the bug this
/// codebase already fixed once.
///
/// One accepted trade-off: on iOS the blob lives in the platform preferences
/// store, not the app documents directory, so a "copy the Documents folder"
/// backup captures every score but not the collections. That is the right side
/// to lose — scores are irreplaceable, and a missing library degrades to
/// [PieceLibrary.empty], which is exactly the app's behaviour before this
/// feature existed.
class PieceLibraryStore {
  static const _key = 'pieceLibrary';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _open() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// The stored library, or [PieceLibrary.empty] when there is none or it is
  /// unreadable.
  ///
  /// Never throws. A corrupt blob costs the user their chips, not their songs:
  /// the list falls back to showing everything, unfiltered — the same principle
  /// as `piece_storage_io.dart`'s "a corrupt index loses titles, not songs".
  Future<PieceLibrary> load() async {
    try {
      final raw = (await _open()).getString(_key);
      if (raw == null || raw.trim().isEmpty) return PieceLibrary.empty;
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) return PieceLibrary.empty;
      return PieceLibrary.fromJson(decoded);
    } catch (_) {
      return PieceLibrary.empty;
    }
  }

  /// Best-effort, like [StaffZoomStore.save] — a write failure must never break
  /// the UI, since the in-memory notifier still holds the value for the session.
  Future<void> save(PieceLibrary library) async {
    try {
      await (await _open()).setString(_key, json.encode(library.toJson()));
    } catch (_) {
      // Ignore: the session-level notifier still holds the value.
    }
  }
}

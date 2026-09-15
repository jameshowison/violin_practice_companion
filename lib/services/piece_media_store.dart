import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/piece_media.dart';

/// Persists the media a user has ADDED to a piece — imported files and
/// recorded demos.
///
/// Deliberately not the whole list. The synthesized score and the bundled
/// tracks are derived from the piece itself (see
/// `PieceRepository.mediaFor`), so storing them would be keeping a second
/// copy of something the build already knows, free to disagree with it after
/// an app update that changes which tracks ship.
class PieceMediaStore {
  String _key(String pieceId) => 'pieceMedia.$pieceId';

  /// Empty for a piece with no user media, and empty for a piece whose stored
  /// list can't be parsed. Individual unparseable entries are dropped and the
  /// rest are kept — see [PieceMedia.fromJson].
  Future<List<PieceMedia>> load(String pieceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(pieceId));
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [for (final entry in list) ?PieceMedia.fromJson(entry)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(String pieceId, List<PieceMedia> media) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(pieceId),
      jsonEncode([for (final m in media) m.toJson()]),
    );
  }

  /// Appends [media], replacing any existing entry with the same id so a
  /// re-import of the same medium updates in place rather than doubling it.
  Future<List<PieceMedia>> add(String pieceId, PieceMedia media) async {
    final current = await load(pieceId);
    final next = [
      for (final m in current)
        if (m.id != media.id) m,
      media,
    ];
    await save(pieceId, next);
    return next;
  }

  Future<List<PieceMedia>> remove(String pieceId, String mediaId) async {
    final next = [
      for (final m in await load(pieceId))
        if (m.id != mediaId) m,
    ];
    await save(pieceId, next);
    return next;
  }

  /// Drops every user medium for a piece. Called when the piece itself is
  /// deleted; the files are removed separately by `deleteMediaFiles`, since
  /// this class owns the index and not the bytes.
  Future<void> clear(String pieceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(pieceId));
  }

  Future<bool> hasAny(String pieceId) async =>
      (await load(pieceId)).isNotEmpty;

  /// A media id that is unique within a piece and safe as a folder name.
  ///
  /// Time-based rather than a counter: a counter would have to be derived from
  /// the current list, and two adds racing on that would collide on a folder
  /// name and one recording would overwrite the other's files.
  static String newMediaId(String prefix, DateTime now) =>
      '${prefix}_${now.millisecondsSinceEpoch}';
}

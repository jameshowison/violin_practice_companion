import 'package:shared_preferences/shared_preferences.dart';

import '../models/tempo_presets.dart';

/// Persistence for [TempoSettings]: one set for the whole app, like the
/// count-in ([CountInStore]) — how slow "slow" is is a fact about the player.
///
/// Never throws: a preferences failure just means the defaults (on load) or a
/// value that lasts only for the session (on save).
class TempoStore {
  /// [key] maps a preference key to the player's (`playerKeyProvider`): the
  /// presets and what was asked about recordings are the player's. A piece's
  /// pinned performance tempo is the piece's, everyone's, and keeps its key.
  TempoStore({String Function(String)? key}) : _key = key ?? _same;

  static String _same(String k) => k;
  final String Function(String) _key;

  static const _prefix = 'tempo.';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _open() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<TempoSettings?> load() async {
    try {
      final p = await _open();
      const d = TempoSettings();
      if (!p.containsKey(_key('${_prefix}preset'))) return null;
      final presetName = p.getString(_key('${_prefix}preset'));
      final preset = TempoPreset.values
              .where((v) => v.name == presetName)
              .firstOrNull ??
          d.preset;
      // Slow and Medium used to be bpm (`tempo.slow`, `tempo.medium`); they
      // are shares of the piece's performance tempo now, under new keys, so an
      // old absolute value is simply not read rather than misread as a %.
      return TempoSettings(
        slowPercent:
            clampPercent(p.getInt(_key('${_prefix}slowPercent')) ?? d.slowPercent),
        mediumPercent: clampPercent(
            p.getInt(_key('${_prefix}mediumPercent')) ?? d.mediumPercent),
        performance:
            clampBpm(p.getInt(_key('${_prefix}performance')) ?? d.performance),
        custom: clampBpm(p.getInt(_key('${_prefix}custom')) ?? d.custom),
        preset: preset,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(TempoSettings s) async {
    try {
      final p = await _open();
      await p.setString(_key('${_prefix}preset'), s.preset.name);
      await p.setInt(_key('${_prefix}slowPercent'), s.slowPercent);
      await p.setInt(_key('${_prefix}mediumPercent'), s.mediumPercent);
      await p.setInt(_key('${_prefix}performance'), s.performance);
      await p.setInt(_key('${_prefix}custom'), s.custom);
    } catch (_) {
      // Ignore: the provider still holds the value for this session.
    }
  }

  String _pieceKey(String pieceId) => '${_prefix}piece.$pieceId';

  /// The performance tempo set by hand for [pieceId], or null to follow its
  /// recordings (or the app-wide default).
  Future<int?> loadPiecePerformance(String pieceId) async {
    try {
      return (await _open()).getInt(_pieceKey(pieceId));
    } catch (_) {
      return null;
    }
  }

  Future<void> savePiecePerformance(String pieceId, int? bpm) async {
    try {
      final p = await _open();
      if (bpm == null) {
        await p.remove(_pieceKey(pieceId));
      } else {
        await p.setInt(_pieceKey(pieceId), clampBpm(bpm));
      }
    } catch (_) {
      // Ignore, as above.
    }
  }

  String _askedKey(String pieceId) =>
      _key('${_prefix}askedRecording.$pieceId');

  /// Whether the user has already been asked to follow [mediaId]'s tempo in
  /// place of [pieceId]'s hand-set one (see `offerRecordingTempo`). Asked once
  /// per recording, whatever the answer. A failure reads as asked, so a broken
  /// preferences store can't put the question up on every load.
  Future<bool> wasAskedAboutRecording(String pieceId, String mediaId) async {
    try {
      return ((await _open()).getStringList(_askedKey(pieceId)) ?? const [])
          .contains(mediaId);
    } catch (_) {
      return true;
    }
  }

  Future<void> markAskedAboutRecording(String pieceId, String mediaId) async {
    try {
      final p = await _open();
      final asked = p.getStringList(_askedKey(pieceId)) ?? const <String>[];
      if (asked.contains(mediaId)) return;
      await p.setStringList(_askedKey(pieceId), [...asked, mediaId]);
    } catch (_) {
      // Ignore, as above.
    }
  }
}

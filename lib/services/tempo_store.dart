import 'package:shared_preferences/shared_preferences.dart';

import '../models/tempo_presets.dart';

/// Persistence for [TempoSettings]: one set for the whole app, like the
/// count-in ([CountInStore]) — how slow "slow" is is a fact about the player.
///
/// Never throws: a preferences failure just means the defaults (on load) or a
/// value that lasts only for the session (on save).
class TempoStore {
  static const _prefix = 'tempo.';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _open() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<TempoSettings?> load() async {
    try {
      final p = await _open();
      const d = TempoSettings();
      if (!p.containsKey('${_prefix}preset')) return null;
      final presetName = p.getString('${_prefix}preset');
      final preset = TempoPreset.values
              .where((v) => v.name == presetName)
              .firstOrNull ??
          d.preset;
      // Slow and Medium used to be bpm (`tempo.slow`, `tempo.medium`); they
      // are shares of the piece's performance tempo now, under new keys, so an
      // old absolute value is simply not read rather than misread as a %.
      return TempoSettings(
        slowPercent:
            clampPercent(p.getInt('${_prefix}slowPercent') ?? d.slowPercent),
        mediumPercent: clampPercent(
            p.getInt('${_prefix}mediumPercent') ?? d.mediumPercent),
        performance:
            clampBpm(p.getInt('${_prefix}performance') ?? d.performance),
        custom: clampBpm(p.getInt('${_prefix}custom') ?? d.custom),
        preset: preset,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(TempoSettings s) async {
    try {
      final p = await _open();
      await p.setString('${_prefix}preset', s.preset.name);
      await p.setInt('${_prefix}slowPercent', s.slowPercent);
      await p.setInt('${_prefix}mediumPercent', s.mediumPercent);
      await p.setInt('${_prefix}performance', s.performance);
      await p.setInt('${_prefix}custom', s.custom);
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
}

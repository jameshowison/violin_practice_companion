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
      int read(TempoPreset t, int fallback) =>
          clampBpm(p.getInt('$_prefix${t.name}') ?? fallback);
      return TempoSettings(
        slow: read(TempoPreset.slow, d.slow),
        medium: read(TempoPreset.medium, d.medium),
        performance: read(TempoPreset.performance, d.performance),
        custom: read(TempoPreset.custom, d.custom),
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
      for (final t in TempoPreset.values) {
        await p.setInt('$_prefix${t.name}', s.bpmFor(t));
      }
    } catch (_) {
      // Ignore: the provider still holds the value for this session.
    }
  }
}

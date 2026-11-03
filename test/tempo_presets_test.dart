import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/tempo_presets.dart';
import 'package:violin_practice_companion/services/tempo_store.dart';

void main() {
  test('defaults are violin practice speeds, Medium selected', () {
    const s = TempoSettings();
    expect(s.bpmFor(TempoPreset.slow), 60);
    expect(s.bpmFor(TempoPreset.medium), 80);
    expect(s.bpmFor(TempoPreset.performance), 100);
    expect(s.bpm, 80);
  });

  test('setting a preset bpm clamps and leaves the others alone', () {
    final s = const TempoSettings()
        .withBpm(TempoPreset.slow, 5)
        .withBpm(TempoPreset.custom, 999)
        .withPreset(TempoPreset.custom);
    expect(s.slow, minBpm);
    expect(s.custom, maxBpm);
    expect(s.medium, 80);
    expect(s.bpm, maxBpm);
  });

  test('store round-trips, and is empty before the first save', () async {
    SharedPreferences.setMockInitialValues({});
    final store = TempoStore();
    expect(await store.load(), isNull);
    final s = const TempoSettings()
        .withBpm(TempoPreset.performance, 112)
        .withPreset(TempoPreset.performance);
    await store.save(s);
    expect(await TempoStore().load(), s);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/tempo_presets.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/tempo_store.dart';

void main() {
  test('defaults: Slow and Medium are 60% and 80% of the piece, Medium selected',
      () {
    const s = TempoSettings();
    expect(s.bpmFor(TempoPreset.slow, 100), 60);
    expect(s.bpmFor(TempoPreset.medium, 100), 80);
    expect(s.bpmFor(TempoPreset.performance, 100), 100);
    expect(s.bpmAt(100), 80);
    expect(s.performance, 100);
  });

  test('presets scale with the piece: Long, Long Ago at its recorded 63', () {
    const s = TempoSettings();
    expect(s.bpmFor(TempoPreset.slow, 62.6), 40); // 37.6, clamped up to 40
    expect(s.bpmFor(TempoPreset.medium, 62.6), 50);
    expect(s.exactBpmFor(TempoPreset.performance, 62.6), 62.6);
    // Custom is absolute, whatever the piece.
    expect(s.bpmFor(TempoPreset.custom, 62.6), 90);
  });

  test('percent, default and custom are clamped; percent ignores other presets',
      () {
    final s = const TempoSettings()
        .withPercent(TempoPreset.slow, 5)
        .withPercent(TempoPreset.medium, 150)
        .withPercent(TempoPreset.performance, 10)
        .withDefaultPerformance(999)
        .withCustom(1)
        .withPreset(TempoPreset.custom);
    expect(s.slowPercent, minPercent);
    expect(s.mediumPercent, maxPercent);
    expect(s.performance, maxBpm);
    expect(s.custom, minBpm);
    expect(s.bpmAt(100), minBpm);
  });

  test('store round-trips, and is empty before the first save', () async {
    SharedPreferences.setMockInitialValues({});
    final store = TempoStore();
    expect(await store.load(), isNull);
    final s = const TempoSettings()
        .withPercent(TempoPreset.slow, 50)
        .withDefaultPerformance(112)
        .withPreset(TempoPreset.performance);
    await store.save(s);
    expect(await TempoStore().load(), s);
  });

  test('old absolute Slow / Medium bpm are not misread as percentages',
      () async {
    SharedPreferences.setMockInitialValues({
      'tempo.preset': 'slow',
      'tempo.slow': 55,
      'tempo.medium': 75,
      'tempo.performance': 110,
    });
    final s = (await TempoStore().load())!;
    expect(s.slowPercent, 60);
    expect(s.mediumPercent, 80);
    expect(s.performance, 110);
    expect(s.preset, TempoPreset.slow);
  });

  test('per-piece performance tempo round-trips and clears', () async {
    SharedPreferences.setMockInitialValues({});
    final store = TempoStore();
    expect(await store.loadPiecePerformance('lightly_row'), isNull);
    await store.savePiecePerformance('lightly_row', 72);
    expect(await TempoStore().loadPiecePerformance('lightly_row'), 72);
    await store.savePiecePerformance('lightly_row', null);
    expect(await TempoStore().loadPiecePerformance('lightly_row'), isNull);
  });

  group('performanceTempoProvider', () {
    const piece = Piece(
        id: 'p', title: 'P', musicXmlAssetPath: 'x.xml', sections: []);

    ProviderContainer make({double? cached}) {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer(overrides: [
        pieceRecordingBpmProvider.overrideWith((ref, id) async => cached),
      ]);
      c.read(selectedPieceProvider.notifier).state = piece;
      return c;
    }

    test('falls back to the app-wide default', () async {
      final c = make();
      await c.read(pieceRecordingBpmProvider('p').future);
      final perf = c.read(performanceTempoProvider);
      expect(perf.bpm, 100);
      expect(perf.source, PerformanceSource.defaultTempo);
      expect(c.read(tempoBpmProvider), 80); // Medium, 80% of 100
    });

    test('the synthesized score follows the cached recording tempo', () async {
      final c = make(cached: 62.6);
      await c.read(pieceRecordingBpmProvider('p').future);
      expect(c.read(performanceTempoProvider).source,
          PerformanceSource.recording);
      expect(c.read(tempoBpmProvider), 50); // 80% of 62.6
    });

    test('a loaded recording stands in for the piece, so Performance is 1.0x',
        () async {
      final c = make(cached: 70);
      await c.read(pieceRecordingBpmProvider('p').future);
      c.read(loadedRecordingBpmProvider.notifier).state = 62.6;
      c.read(tempoSettingsProvider.notifier).select(TempoPreset.performance);
      expect(c.read(exactTempoBpmProvider), 62.6);
    });

    test('a tempo set for the piece wins over its recordings', () async {
      final c = make(cached: 62.6);
      await c.read(pieceRecordingBpmProvider('p').future);
      c.read(piecePerformanceOverrideProvider('p').notifier).set(72);
      final perf = c.read(performanceTempoProvider);
      expect(perf.bpm, 72);
      expect(perf.source, PerformanceSource.piece);
      c.read(piecePerformanceOverrideProvider('p').notifier).set(null);
      expect(c.read(performanceTempoProvider).bpm, 62.6);
    });
  });
}

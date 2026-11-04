/// The synthesized playback's tempo, chosen from named practice speeds.
///
/// Three speeds a violinist actually practises at — slow, working, and the
/// piece's real tempo — plus a typed-in custom value. The bpm behind each name
/// is a setting, so "Slow" can mean whatever slow means for this player.
enum TempoPreset { slow, medium, performance, custom }

extension TempoPresetLabel on TempoPreset {
  String get label => switch (this) {
        TempoPreset.slow => 'Slow',
        TempoPreset.medium => 'Medium',
        TempoPreset.performance => 'Performance',
        TempoPreset.custom => 'Custom',
      };

  /// For tight spots: the phone's play tray and the tempo slider's marks.
  String get shortLabel => switch (this) {
        TempoPreset.slow => 'Slow',
        TempoPreset.medium => 'Med',
        TempoPreset.performance => 'Perf',
        TempoPreset.custom => 'Custom',
      };
}

/// Lowest and highest tempo the custom field and the preset settings accept —
/// a mechanical metronome's range, which also keeps the tempo slider's marks
/// far enough apart to label.
const minBpm = 40;
const maxBpm = 208;

int clampBpm(int bpm) => bpm.clamp(minBpm, maxBpm);

/// Lowest and highest share of the performance tempo Slow and Medium can be.
const minPercent = 20;
const maxPercent = 100;

int clampPercent(int pct) => pct.clamp(minPercent, maxPercent);

/// The app-wide half of the tempo presets, and which preset is selected.
///
/// Performance is a fact about the PIECE (its teacher recording's tempo, or a
/// value set for it), so it is passed in; Slow and Medium are shares of it, so
/// they scale with the piece — 60% of a 63 bpm Long, Long Ago is as slow,
/// relatively, as 60% of a 100 bpm Allegro. [performance] here is only the
/// default for a piece with neither a recording nor a value of its own.
/// Custom is an absolute bpm.
///
/// Defaults: 60% and 80% are the usual slow- and working-practice fractions;
/// 100 bpm a typical performance tempo for early Suzuki-book repertoire.
class TempoSettings {
  const TempoSettings({
    this.slowPercent = 60,
    this.mediumPercent = 80,
    this.performance = 100,
    this.custom = 90,
    this.preset = TempoPreset.medium,
  });

  final int slowPercent;
  final int mediumPercent;
  final int performance;
  final int custom;
  final TempoPreset preset;

  /// [p]'s tempo for a piece whose performance tempo is [performanceBpm],
  /// unrounded so a recording's Performance can come out at exactly 1.0x.
  double exactBpmFor(TempoPreset p, double performanceBpm) {
    final v = switch (p) {
      TempoPreset.slow => performanceBpm * slowPercent / 100,
      TempoPreset.medium => performanceBpm * mediumPercent / 100,
      TempoPreset.performance => performanceBpm,
      TempoPreset.custom => custom.toDouble(),
    };
    return v.clamp(minBpm.toDouble(), maxBpm.toDouble());
  }

  /// [p]'s tempo, rounded — what the synthesized score plays and the tray shows.
  int bpmFor(TempoPreset p, double performanceBpm) =>
      exactBpmFor(p, performanceBpm).round();

  /// The selected preset's tempo at [performanceBpm].
  int bpmAt(double performanceBpm) => bpmFor(preset, performanceBpm);

  /// Slow's or Medium's share of the performance tempo.
  int percentFor(TempoPreset p) => switch (p) {
        TempoPreset.slow => slowPercent,
        TempoPreset.medium => mediumPercent,
        _ => 100,
      };

  TempoSettings _copy({
    int? slowPercent,
    int? mediumPercent,
    int? performance,
    int? custom,
    TempoPreset? preset,
  }) =>
      TempoSettings(
        slowPercent: slowPercent ?? this.slowPercent,
        mediumPercent: mediumPercent ?? this.mediumPercent,
        performance: performance ?? this.performance,
        custom: custom ?? this.custom,
        preset: preset ?? this.preset,
      );

  /// Sets Slow's or Medium's share; ignored for the other presets.
  TempoSettings withPercent(TempoPreset p, int pct) => switch (p) {
        TempoPreset.slow => _copy(slowPercent: clampPercent(pct)),
        TempoPreset.medium => _copy(mediumPercent: clampPercent(pct)),
        _ => this,
      };

  TempoSettings withDefaultPerformance(int bpm) =>
      _copy(performance: clampBpm(bpm));

  TempoSettings withCustom(int bpm) => _copy(custom: clampBpm(bpm));

  TempoSettings withPreset(TempoPreset p) => _copy(preset: p);

  @override
  bool operator ==(Object other) =>
      other is TempoSettings &&
      other.slowPercent == slowPercent &&
      other.mediumPercent == mediumPercent &&
      other.performance == performance &&
      other.custom == custom &&
      other.preset == preset;

  @override
  int get hashCode =>
      Object.hash(slowPercent, mediumPercent, performance, custom, preset);
}

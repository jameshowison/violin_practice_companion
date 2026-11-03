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

/// The bpm for each preset and which one is selected.
///
/// Defaults are beginner-to-intermediate violin practice speeds (quarter-note
/// beats): 60 is the classic slow-practice metronome mark, 80 a comfortable
/// working tempo, 100 a typical performance tempo for the early Suzuki-book
/// repertoire this app is mostly used with.
class TempoSettings {
  const TempoSettings({
    this.slow = 60,
    this.medium = 80,
    this.performance = 100,
    this.custom = 90,
    this.preset = TempoPreset.medium,
  });

  final int slow;
  final int medium;
  final int performance;
  final int custom;
  final TempoPreset preset;

  int bpmFor(TempoPreset p) => switch (p) {
        TempoPreset.slow => slow,
        TempoPreset.medium => medium,
        TempoPreset.performance => performance,
        TempoPreset.custom => custom,
      };

  /// The tempo playback should run at.
  int get bpm => bpmFor(preset);

  TempoSettings withBpm(TempoPreset p, int bpm) {
    final v = clampBpm(bpm);
    return TempoSettings(
      slow: p == TempoPreset.slow ? v : slow,
      medium: p == TempoPreset.medium ? v : medium,
      performance: p == TempoPreset.performance ? v : performance,
      custom: p == TempoPreset.custom ? v : custom,
      preset: preset,
    );
  }

  TempoSettings withPreset(TempoPreset p) => TempoSettings(
        slow: slow,
        medium: medium,
        performance: performance,
        custom: custom,
        preset: p,
      );

  @override
  bool operator ==(Object other) =>
      other is TempoSettings &&
      other.slow == slow &&
      other.medium == medium &&
      other.performance == performance &&
      other.custom == custom &&
      other.preset == preset;

  @override
  int get hashCode => Object.hash(slow, medium, performance, custom, preset);
}

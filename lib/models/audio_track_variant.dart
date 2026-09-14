/// The three independent play-along audio variants a piece can have — played
/// one at a time, never mixed (see the audio-sync plan's "no simultaneous
/// multi-track mixing" decision).
enum AudioTrackVariant { mix, melody, chords }

extension AudioTrackVariantX on AudioTrackVariant {
  /// The filename stem (`mix.mp3`, `melody.mp3`, `chords.mp3`) and the key
  /// this variant's calibration is stored under.
  String get id => name;

  String get label => switch (this) {
        AudioTrackVariant.mix => 'Mix',
        AudioTrackVariant.melody => 'Melody',
        AudioTrackVariant.chords => 'Chords',
      };

  String assetPathIn(String audioFolder) => 'assets/audio/$audioFolder/$id.mp3';
}

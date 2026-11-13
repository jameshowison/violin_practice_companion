import 'piece_catalog.dart';
/// The independent play-along audio variants a piece can have — played one at
/// a time, never mixed (see the audio-sync plan's "no simultaneous multi-track
/// mixing" decision). There was a third, `mix`, but both bundled pieces
/// shipped it as a byte-for-byte copy of `melody.mp3`, so it went.
enum AudioTrackVariant { melody, chords }

extension AudioTrackVariantX on AudioTrackVariant {
  /// The filename stem (`melody.mp3`, `chords.mp3`) and the key
  /// this variant's calibration is stored under.
  String get id => name;

  String get label => switch (this) {
        AudioTrackVariant.melody => 'Melody',
        AudioTrackVariant.chords => 'Chords',
      };

  String assetPathIn(String audioFolder) => '${bundledAudioDir(audioFolder)}/$id.mp3';
}

import 'tuning.dart';

/// How a transposing instrument's written notes relate to the pitches it
/// sounds. A tuner hears sounding pitch; a clarinettist reads, and thinks
/// in, written pitch, so the tuner shows the written name.
///
/// [semitones] is sounding minus written, as MusicXML's `<transpose>`
/// counts it (`<chromatic>` plus 12 × `<octave-change>`): a B♭ clarinet's
/// written C sounds the B♭ below, so it is −2.
class Transposition {
  const Transposition(this.semitones, {required this.name});

  /// Sounding pitch minus written pitch, in semitones.
  final int semitones;

  /// A short label, such as `B♭`.
  final String name;

  /// Non-transposing: written as sounding (violin, flute, oboe, piano).
  static const concert = Transposition(0, name: 'C');

  /// Clarinet, trumpet, soprano saxophone: written C sounds B♭ below.
  static const bFlat = Transposition(-2, name: 'B♭');

  /// A clarinet: written C sounds the A below.
  static const a = Transposition(-3, name: 'A');

  /// Horn, cor anglais: written C sounds the F below.
  static const f = Transposition(-7, name: 'F');

  /// Alto saxophone: written C sounds the E♭ a sixth below.
  static const eFlatAlto = Transposition(-9, name: 'E♭');

  /// E♭ clarinet: written C sounds the E♭ above.
  static const eFlatHigh = Transposition(3, name: 'E♭ (high)');

  /// Tenor saxophone, bass clarinet: written C sounds a ninth below.
  static const bFlatTenor = Transposition(-14, name: 'B♭ (tenor)');

  /// Baritone saxophone: written C sounds an octave and a sixth below.
  static const eFlatBaritone = Transposition(-21, name: 'E♭ (baritone)');

  /// Guitar, double bass: written an octave above where they sound.
  static const octaveDown = Transposition(-12, name: '8vb');

  /// Piccolo, soprano recorder: written an octave below where they sound.
  static const octaveUp = Transposition(12, name: '8va');

  /// The written note that sounds [soundingMidi].
  int written(int soundingMidi) => soundingMidi - semitones;

  /// The note that sounds when [writtenMidi] is played.
  int sounding(int writtenMidi) => writtenMidi + semitones;

  /// The written name of a target, such as `D4` for a B♭ instrument's C4.
  String writtenName(TunedString target) => midiNoteName(written(target.midi));

  @override
  bool operator ==(Object other) => other is Transposition && other.semitones == semitones;

  @override
  int get hashCode => semitones.hashCode;

  @override
  String toString() => 'Transposition($name, $semitones)';
}

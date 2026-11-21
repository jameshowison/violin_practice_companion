/// A part's `<transpose>`: how far what sounds is from what is written,
/// sounding minus written, as MusicXML counts it. A B♭ clarinet is diatonic
/// -1, chromatic -2: its written D sounds C.
///
/// Read and exposed only; nothing in this library applies it to the notes.
class Transpose {
  /// Semitones within the octave (MusicXML `<chromatic>`).
  final int chromatic;

  /// Letter names (MusicXML `<diatonic>`): how a transposed note is spelled.
  final int diatonic;

  /// Whole octaves on top (MusicXML `<octave-change>`).
  final int octaveChange;

  const Transpose({
    required this.chromatic,
    this.diatonic = 0,
    this.octaveChange = 0,
  });

  /// The whole move in semitones, octaves included.
  int get semitones => chromatic + 12 * octaveChange;

  /// The MIDI note that sounds for a written [writtenMidi].
  int soundingMidi(int writtenMidi) => writtenMidi + semitones;

  @override
  bool operator ==(Object other) =>
      other is Transpose &&
      other.chromatic == chromatic &&
      other.diatonic == diatonic &&
      other.octaveChange == octaveChange;

  @override
  int get hashCode => Object.hash(chromatic, diatonic, octaveChange);

  @override
  String toString() => 'Transpose(chromatic: $chromatic, diatonic: $diatonic, '
      'octaveChange: $octaveChange)';
}

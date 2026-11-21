/// A clef, as MusicXML writes it: `<sign>` and `<line>`.
typedef Clef = ({String sign, int line});

const Clef trebleClef = (sign: 'G', line: 2);
const Clef altoClef = (sign: 'C', line: 3);
const Clef bassClef = (sign: 'F', line: 4);

/// How a piece written in another clef is transcribed for an instrument,
/// before it is moved by octaves into the instrument's range.
enum Transcription {
  /// The same notes, in the instrument's clef. A recording of the source
  /// still matches what is shown, note for note.
  none,

  /// A fifth lower: a violin tune on a viola keeps the violin's finger
  /// patterns, a string lower (some method books transcribe so). The key
  /// changes, so a recording of the violin part no longer matches the notes.
  fifthDown,
}

/// What the instrument layer needs to know about an instrument to show a
/// piece for it (docs/family/layers.md): the clef it reads and the range a
/// beginner plays in, which decides the octave a piece written in another
/// clef is shown at.
///
/// Fingering, palette, playback sound and tuning still live where they did
/// (`FingeringMapper`, `ViolinStringPalette`, `midi_patch.json`, the tuner);
/// they join the profile as each one gains a second instrument.
class InstrumentProfile {
  final String id;
  final String displayName;

  /// Whose instrument layer this instrument's string choices are kept in
  /// (`InstrumentLayerStore`): each instrument its own.
  final String layerId;

  /// The clef this instrument reads.
  final Clef clef;

  /// The first-position range, as MIDI numbers: open lowest string to 4th
  /// finger on the highest.
  final int lowestMidi;
  final int highestMidi;

  /// How a part written in another clef is transcribed (see [Transcription]).
  final Transcription transcription;

  /// The open strings, lowest first: their names, and their MIDI numbers.
  final List<String> strings;
  final List<int> openMidi;

  const InstrumentProfile({
    required this.id,
    required this.displayName,
    required this.layerId,
    required this.clef,
    required this.lowestMidi,
    required this.highestMidi,
    required this.strings,
    required this.openMidi,
    this.transcription = Transcription.none,
  });

  InstrumentProfile withTranscription(Transcription t) => InstrumentProfile(
        id: id,
        displayName: displayName,
        layerId: layerId,
        clef: clef,
        lowestMidi: lowestMidi,
        highestMidi: highestMidi,
        strings: strings,
        openMidi: openMidi,
        transcription: t,
      );

  /// Whether [midi] is both an open string and a 4th finger on the string
  /// below: the notes where the fingering is a choice (violin D4, A4, E5;
  /// viola G3, D4, A4).
  bool hasFourthFingerChoice(int midi) =>
      midi != openMidi.first && openMidi.contains(midi);

  /// G3 to B5.
  static const violin = InstrumentProfile(
    id: 'violin',
    displayName: 'Violin',
    layerId: 'violin',
    clef: trebleClef,
    lowestMidi: 55,
    highestMidi: 83,
    strings: ['G', 'D', 'A', 'E'],
    openMidi: [55, 62, 69, 76],
  );

  /// Tuned like the violin (G D A E), read in treble at sounding pitch. Its
  /// range here is the violin's first position, which is also what the fret
  /// numbers stay within.
  static const mandolin = InstrumentProfile(
    id: 'mandolin',
    displayName: 'Mandolin',
    layerId: 'mandolin',
    clef: trebleClef,
    lowestMidi: 55,
    highestMidi: 83,
    strings: ['G', 'D', 'A', 'E'],
    openMidi: [55, 62, 69, 76],
  );

  /// A fifth below the violin (C G D A), read in alto clef. First position
  /// runs C3 to E5. Its fingering is the violin's, a string lower.
  static const viola = InstrumentProfile(
    id: 'viola',
    displayName: 'Viola',
    layerId: 'viola',
    clef: altoClef,
    lowestMidi: 48,
    highestMidi: 76,
    strings: ['C', 'G', 'D', 'A'],
    openMidi: [48, 55, 62, 69],
  );
}

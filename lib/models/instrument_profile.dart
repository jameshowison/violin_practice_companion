/// A clef, as MusicXML writes it: `<sign>` and `<line>`.
typedef Clef = ({String sign, int line});

const Clef trebleClef = (sign: 'G', line: 2);
const Clef altoClef = (sign: 'C', line: 3);
const Clef bassClef = (sign: 'F', line: 4);

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
  /// (`InstrumentLayerStore`). The mandolin's frets follow the violin
  /// fingering, so it shares the violin's.
  final String layerId;

  /// The clef this instrument reads.
  final Clef clef;

  /// The first-position range, as MIDI numbers: open lowest string to 4th
  /// finger on the highest.
  final int lowestMidi;
  final int highestMidi;

  const InstrumentProfile({
    required this.id,
    required this.displayName,
    required this.layerId,
    required this.clef,
    required this.lowestMidi,
    required this.highestMidi,
  });

  /// G3 to B5.
  static const violin = InstrumentProfile(
    id: 'violin',
    displayName: 'Violin',
    layerId: 'violin',
    clef: trebleClef,
    lowestMidi: 55,
    highestMidi: 83,
  );

  /// Tuned like the violin (G D A E), read in treble at sounding pitch. Its
  /// range here is the violin's first position, which is also what the fret
  /// numbers stay within.
  static const mandolin = InstrumentProfile(
    id: 'mandolin',
    displayName: 'Mandolin',
    layerId: 'violin',
    clef: trebleClef,
    lowestMidi: 55,
    highestMidi: 83,
  );
}

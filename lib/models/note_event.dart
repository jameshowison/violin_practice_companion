enum NoteValue { whole, half, quarter, eighth, sixteenth }

/// The church modes, declared in rotation order from the relative major, so
/// `index` IS the mode's degree within that major scale. `major` and `minor`
/// keep their familiar names rather than ionian/aeolian — that's what MusicXML
/// and the rest of the app call them.
///
/// Modes matter for trad/folk tunes: `K: Amix` (Old Joe Clark) carries D major's
/// two sharps, but its tonic is A. Storing only the signature would make the
/// opening A chord read as V instead of I.
enum KeyMode { major, dorian, phrygian, lydian, mixolydian, minor, locrian }

extension KeyModeInfo on KeyMode {
  /// Scale degree (0-based) of this mode's tonic within its relative major.
  int get rotation => index;

  /// Semitones from the relative-major tonic up to this mode's tonic.
  int get semitonesAboveRelativeMajor => const [0, 2, 4, 5, 7, 9, 11][index];

  /// True for the modes with a minor third. These are conventionally analyzed
  /// against the natural-minor scale, so e.g. dorian's ♭7 chord reads ♭VII —
  /// the bright modes (ionian/lydian/mixolydian) are read against major.
  bool get hasMinorThird =>
      const [false, true, true, false, false, true, true][index];
}

enum DisplayMode { staff, staffFingering, jianpu, fingering, combined, tab }

class NoteEvent {
  final String pitch;
  final int midiNumber;
  final int octave;
  final NoteValue noteValue;
  final bool dotted;
  final bool isRest;
  final int? scoreFinger;

  /// The visible accidental sign, as the raw MusicXML `<accidental>` value
  /// (`'natural'`, `'sharp'`, `'flat'`, …) — `null` means no sign is drawn and
  /// the note follows the key signature. This is the *displayed* accidental,
  /// distinct from the sounding alteration encoded in [pitch]: e.g. a courtesy
  /// natural on a C in G major has `displayAccidental: 'natural'` while [pitch]
  /// is still `'C5'` (alter 0). Without it, the editor can't show or remove a
  /// redundant accidental.
  final String? displayAccidental;

  // Populated by JianpuConverter
  final int? jianpuNumber;
  final int? jianpuOctaveDots;
  final bool? jianpuAccidentalSharp;

  // Populated by FingeringMapper
  final String? fingerString;
  final String? fingerNumber;

  /// Chord symbol that begins at this note, as a display string built from the
  /// MusicXML `<harmony>` that immediately precedes it (e.g. `'A'`, `'E7'`,
  /// `'Am7'`, `'D/F#'`). Null when no chord starts here. Populated by
  /// [MusicXmlParser]; consumed by the chord-symbol display (see
  /// [ChordXmlInjector]).
  final String? chordSymbol;

  /// True when this note is a *chord member* — a MusicXML `<note>` carrying a
  /// `<chord/>` child, i.e. the 2nd+ note stacked on one stem. It sounds at the
  /// same onset as the preceding (primary) note and adds no time; the primary
  /// note governs the chord's duration. Populated by [MusicXmlParser]; consumed
  /// by MidiGenerator so chord notes play together instead of sequentially.
  final bool isChord;

  const NoteEvent({
    required this.pitch,
    required this.midiNumber,
    required this.octave,
    required this.noteValue,
    required this.dotted,
    required this.isRest,
    this.scoreFinger,
    this.displayAccidental,
    this.jianpuNumber,
    this.jianpuOctaveDots,
    this.jianpuAccidentalSharp,
    this.fingerString,
    this.fingerNumber,
    this.chordSymbol,
    this.isChord = false,
  });

  NoteEvent copyWith({
    String? pitch,
    int? midiNumber,
    int? octave,
    NoteValue? noteValue,
    bool? dotted,
    bool? isRest,
    int? scoreFinger,
    String? displayAccidental,
    int? jianpuNumber,
    int? jianpuOctaveDots,
    bool? jianpuAccidentalSharp,
    String? fingerString,
    String? fingerNumber,
    String? chordSymbol,
    bool? isChord,
  }) =>
      NoteEvent(
        pitch: pitch ?? this.pitch,
        midiNumber: midiNumber ?? this.midiNumber,
        octave: octave ?? this.octave,
        noteValue: noteValue ?? this.noteValue,
        dotted: dotted ?? this.dotted,
        isRest: isRest ?? this.isRest,
        scoreFinger: scoreFinger ?? this.scoreFinger,
        displayAccidental: displayAccidental ?? this.displayAccidental,
        jianpuNumber: jianpuNumber ?? this.jianpuNumber,
        jianpuOctaveDots: jianpuOctaveDots ?? this.jianpuOctaveDots,
        jianpuAccidentalSharp:
            jianpuAccidentalSharp ?? this.jianpuAccidentalSharp,
        fingerString: fingerString ?? this.fingerString,
        fingerNumber: fingerNumber ?? this.fingerNumber,
        chordSymbol: chordSymbol ?? this.chordSymbol,
        isChord: isChord ?? this.isChord,
      );
}

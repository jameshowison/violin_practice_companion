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

/// One lyric syllable: a MusicXML `<lyric>`'s `<text>`, `<syllabic>`
/// (`single`/`begin`/`middle`/`end` — where it sits in its word, which is what
/// draws the hyphens) and whether it carries an `<extend/>` (held over the
/// following notes).
class Lyric {
  final String text;
  final String syllabic;
  final bool extend;

  const Lyric(this.text, {this.syllabic = 'single', this.extend = false});

  /// Whether this syllable carries on a word begun on an earlier note.
  bool get continuesWord => syllabic == 'middle' || syllabic == 'end';

  /// Whether its word goes on to a later note.
  bool get wordGoesOn => syllabic == 'begin' || syllabic == 'middle';

  /// This syllable followed by [next] as one: the joint is a hyphen inside a
  /// word, else a space, and the result's place in its word is the first's
  /// start and the second's end. How the measure editor keeps a deleted note's
  /// words rather than losing them.
  Lyric mergedWith(Lyric next) {
    final starts = continuesWord, goesOn = next.wordGoesOn;
    return Lyric(
      '$text${wordGoesOn ? '' : ' '}${next.text}',
      syllabic: starts
          ? (goesOn ? 'middle' : 'end')
          : (goesOn ? 'begin' : 'single'),
      extend: next.extend,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Lyric &&
      other.text == text &&
      other.syllabic == syllabic &&
      other.extend == extend;

  @override
  int get hashCode => Object.hash(text, syllabic, extend);

  @override
  String toString() => 'Lyric($text, $syllabic${extend ? ', extend' : ''})';
}

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

  /// The lyric syllable sung on this note, by verse number (1-based, as in
  /// MusicXML `<lyric number>`). Empty when nothing is sung here — a rest, or a
  /// note a previous syllable is held over. Populated by [MusicXmlParser]; the
  /// staff views engrave lyrics from the xml itself (see [LyricXmlInjector]),
  /// so this is what the verse picker counts from — and what the measure
  /// editor writes back, so a syllable travels with its note through an edit.
  final Map<int, Lyric> lyrics;

  /// Tied INTO the next note (MusicXML `<tie type="start"/>`): this note's
  /// sound carries on through it instead of being struck again. A note in the
  /// middle of a chain is both [tieStart] and [tieStop].
  final bool tieStart;

  /// Tied FROM the previous note (`<tie type="stop"/>`): a continuation, held
  /// rather than struck. Still a note of its own in the score — it has its own
  /// notehead, its own time and its own highlight — but [MidiGenerator] folds
  /// its sound into the note it continues, provided they share a pitch and
  /// follow each other in performance.
  final bool tieStop;

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
    this.lyrics = const {},
    this.tieStart = false,
    this.tieStop = false,
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
    Map<int, Lyric>? lyrics,
    bool? tieStart,
    bool? tieStop,
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
        lyrics: lyrics ?? this.lyrics,
        tieStart: tieStart ?? this.tieStart,
        tieStop: tieStop ?? this.tieStop,
      );
}

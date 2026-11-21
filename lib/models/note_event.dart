import 'duration_step.dart';

/// Last, not in length order: `SectionDetector` keys notes by [index], and a
/// new value at the end leaves every existing one where it was.
enum NoteValue { whole, half, quarter, eighth, sixteenth, thirtySecond }

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

/// A string player's bow direction mark: MusicXML `<technical><down-bow/>`
/// (⊓, pull) or `<up-bow/>` (V, push).
enum Bowing { down, up }

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
  /// The note's own MusicXML `<fingering>` — printed in the score, or (0 or
  /// 4 on D4/A4/E5) set in the measure editor to pin open string vs 4th
  /// finger, which [FingeringMapper] then obeys. `copyWith` can only clear
  /// it via `clearScoreFinger`.
  final int? scoreFinger;

  /// The visible accidental sign, as the raw MusicXML `<accidental>` value
  /// (`'natural'`, `'sharp'`, `'flat'`, …) — `null` means no sign is drawn and
  /// the note follows the key signature. This is the *displayed* accidental,
  /// distinct from the sounding alteration encoded in [pitch]: e.g. a courtesy
  /// natural on a C in G major has `displayAccidental: 'natural'` while [pitch]
  /// is still `'C5'` (alter 0). Without it, the editor can't show or remove a
  /// redundant accidental.
  final String? displayAccidental;

  /// What the app has worked out about this note that MusicXML doesn't say:
  /// how to play it on an instrument (a fingering), or how to write it in
  /// another notation (Jianpu). This model only carries it, through
  /// [copyWith] and the editor, and never reads it; the app gives it a type
  /// and getters (`lib/models/note_annotation.dart`). Null until a pass fills
  /// it in.
  final Object? annotation;

  /// Chord symbol that begins at this note, as a display string built from the
  /// MusicXML `<harmony>` that immediately precedes it (e.g. `'A'`, `'E7'`,
  /// `'Am7'`, `'D/F#'`). Null when no chord starts here. Populated by
  /// [MusicXmlParser]; consumed by the chord bars (`chordRunRegions`) and the
  /// footer diagrams (`pieceChordShapesProvider`). The engraved symbols come
  /// from the xml's own `<harmony>`, not from this (see [ChordXmlInjector]).
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

  /// The note's tuplet ratio — MusicXML `<time-modification>`: [actual] notes
  /// in the time of [normal]. A triplet eighth is `(actual: 3, normal: 2)` and
  /// lasts two-thirds of a plain eighth. Null for a note outside any tuplet.
  /// A tuplet group is a run of consecutive notes carrying one (see
  /// [tupletGroups]).
  final ({int actual, int normal})? tuplet;

  /// The bow direction mark on this note, if any — MusicXML
  /// `<technical><up-bow/>` / `<down-bow/>`. Read by [MusicXmlParser], set in
  /// the measure editor, written back by `MeasureXmlEditor`.
  final Bowing? bowing;

  /// The rest of this note's `<notations>`, which nothing in the app models
  /// but somebody wrote: slurs, articulations (staccato, accent, tenuto…),
  /// ornaments, fermatas, and any `<technical>` mark other than the fingering
  /// and the bowing. Each entry is one child element of `<notations>`,
  /// serialized as XML, in document order.
  ///
  /// Opaque on purpose: the measure editor rebuilds a bar's `<note>` elements
  /// from [NoteEvent]s, and this is what lets those marks ride along with
  /// their note — through a pitch change, a duration change, a move — instead
  /// of being dropped. A fresh note has none.
  final List<String> carriedNotations;

  const NoteEvent({
    required this.pitch,
    required this.midiNumber,
    required this.octave,
    required this.noteValue,
    required this.dotted,
    required this.isRest,
    this.scoreFinger,
    this.displayAccidental,
    this.annotation,
    this.chordSymbol,
    this.isChord = false,
    this.lyrics = const {},
    this.tieStart = false,
    this.tieStop = false,
    this.tuplet,
    this.bowing,
    this.carriedNotations = const [],
  });

  /// How long this note lasts, in 32nd-note units (quarter = 8), its tuplet
  /// applied: a triplet eighth is 8/3. Exact for a whole group, so sum it
  /// over a bar and round once — see [unitsOf].
  double get units {
    final base = thirtySecondUnits(noteValue, dotted).toDouble();
    final t = tuplet;
    return t == null ? base : base * t.normal / t.actual;
  }

  NoteEvent copyWith({
    String? pitch,
    int? midiNumber,
    int? octave,
    NoteValue? noteValue,
    bool? dotted,
    bool? isRest,
    int? scoreFinger,
    String? displayAccidental,
    Object? annotation,
    String? chordSymbol,
    bool? isChord,
    Map<int, Lyric>? lyrics,
    bool? tieStart,
    bool? tieStop,
    ({int actual, int normal})? tuplet,
    Bowing? bowing,
    List<String>? carriedNotations,
    bool clearTuplet = false,
    bool clearScoreFinger = false,
    bool clearBowing = false,
  }) =>
      NoteEvent(
        pitch: pitch ?? this.pitch,
        midiNumber: midiNumber ?? this.midiNumber,
        octave: octave ?? this.octave,
        noteValue: noteValue ?? this.noteValue,
        dotted: dotted ?? this.dotted,
        isRest: isRest ?? this.isRest,
        scoreFinger:
            clearScoreFinger ? null : (scoreFinger ?? this.scoreFinger),
        displayAccidental: displayAccidental ?? this.displayAccidental,
        annotation: annotation ?? this.annotation,
        chordSymbol: chordSymbol ?? this.chordSymbol,
        isChord: isChord ?? this.isChord,
        lyrics: lyrics ?? this.lyrics,
        tieStart: tieStart ?? this.tieStart,
        tieStop: tieStop ?? this.tieStop,
        tuplet: clearTuplet ? null : (tuplet ?? this.tuplet),
        bowing: clearBowing ? null : (bowing ?? this.bowing),
        carriedNotations: carriedNotations ?? this.carriedNotations,
      );
}

/// The time [notes] take, in 32nd-note units, tuplets applied. Chord members
/// add none: they sound with the note before them. Rounded once at the end, so
/// a whole triplet group counts exactly (three triplet eighths are 8, a
/// quarter) and a broken one comes out as near as a bar total can be.
int unitsOf(Iterable<NoteEvent> notes) {
  var sum = 0.0;
  for (final n in notes) {
    if (!n.isChord) sum += n.units;
  }
  return sum.round();
}

/// Index ranges (start inclusive, end exclusive) of the tuplet groups in
/// [notes]: runs of consecutive notes with the same [NoteEvent.tuplet], each
/// closed once it has filled its time — `actual` of its shortest value, so
/// three triplet eighths, or a triplet quarter and eighth. Chord members ride
/// with their primary note.
List<(int, int)> tupletGroups(List<NoteEvent> notes) {
  final groups = <(int, int)>[];
  int? start;
  var nominal = 0;
  var shortest = 0;
  void close(int end) {
    groups.add((start!, end));
    start = null;
    nominal = 0;
    shortest = 0;
  }

  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    if (n.isChord && i > 0) continue;
    final t = n.tuplet;
    // A run ends unfinished at a plain note or a different ratio.
    if (start != null && t != notes[start!].tuplet) close(i);
    if (t == null) continue;
    start ??= i;
    final u = thirtySecondUnits(n.noteValue, n.dotted);
    nominal += u;
    if (shortest == 0 || u < shortest) shortest = u;
    if (nominal >= t.actual * shortest) {
      var end = i + 1;
      while (end < notes.length && notes[end].isChord) {
        end++;
      }
      close(end);
    }
  }
  if (start != null) close(notes.length);
  return groups;
}

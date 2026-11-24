import 'package:pitch_tuner/pitch_tuner.dart' show Transposition;
import 'package:score_sync/score_sync.dart' show AlignmentProfile;

import 'recorder_fingering.dart';

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

/// How a string player's hand covers one string in first position, which
/// decides the fingering table and the notes where a finger is a choice.
enum HandFrame {
  /// Four fingers over a perfect fourth: the 4th finger reaches the next
  /// string's open note (violin, viola, mandolin). Its 2 and 3 move low or
  /// high (`2L`, `3H`) with the key.
  fourth,

  /// Four fingers a semitone apart, over a minor third (the cello). A
  /// backward extension of the 1st (`1L`) reaches a semitone under it, a
  /// forward one of the 4th (`4H`) a semitone over; the next open string is
  /// a tone beyond that, so no note is both an open string and a 4th finger.
  minorThird,
}

/// What the instrument layer needs to know about an instrument to show a
/// piece for it (docs/family/layers.md): the clef it reads and the range a
/// beginner plays in, which decides the octave a piece written in another
/// clef is shown at.
///
/// Fingering, palette, playback sound and tuning still live where they did
/// (`FingeringMapper`, `ViolinStringPalette`, `midi_patch.json`, the tuner);
/// they join the profile as each one gains a second instrument. A wind's
/// fingering chart (the recorder's) is [fingeringChart].
class InstrumentProfile {
  final String id;
  final String displayName;

  /// Whose instrument layer this instrument's string choices are kept in
  /// (`InstrumentLayerStore`): each instrument its own.
  final String layerId;

  /// The clef this instrument reads.
  final Clef clef;

  /// The first-position range, as MIDI numbers: open lowest string to 4th
  /// finger on the highest. For a transposing instrument it is the WRITTEN
  /// range, as the instrument reads it (see [transposition]).
  final int lowestMidi;
  final int highestMidi;

  /// How a part written in another clef is transcribed (see [Transcription]).
  final Transcription transcription;

  /// The open strings, lowest first: their names, and their MIDI numbers.
  /// Both empty for an instrument without strings (a wind): no string
  /// fingering, no open-or-4th choice, no string colours ([hasStrings]).
  final List<String> strings;
  final List<int> openMidi;

  /// How the instrument's written notes sound: [Transposition.concert] for
  /// the strings, an octave up for the soprano recorder.
  ///
  /// Where pitch is which (decided for the recorder, the first transposing
  /// instrument; docs/family/windlings-app.md):
  ///
  /// - The stored **source** is concert pitch, as it always was.
  /// - The **view** (`InstrumentView`) is the written part: the source moved
  ///   down by [Transposition.semitones], then by whole octaves into
  ///   [lowestMidi]..[highestMidi]. What is engraved, annotated, named and
  ///   edited, and so what `parsedPieceProvider`'s notes carry.
  /// - **Sound** is the written note plus [Transposition.semitones]: the
  ///   score's MIDI schedule (`MidiGenerator.soundingSemitones`), which both
  ///   playback and the aligner's reference read.
  /// - The **tuner** hears sounding pitch and names the written note
  ///   ([Transposition.writtenName]).
  final Transposition transposition;

  /// What the score aligner needs to know about the instrument: the chroma
  /// band, how long a note rings into a rest, the onset weight
  /// ([AlignmentProfile]). A recording is aligned with the profile of the
  /// instrument the piece is viewed as when it is aligned.
  ///
  /// A cached alignment is not invalidated when the instrument changes: it
  /// stays as it was computed until the medium is realigned (or
  /// `MediaAlignmentStore.alignerVersion` is bumped).
  final AlignmentProfile alignment;

  /// How the hand covers a string ([HandFrame]); meaningless without strings.
  final HandFrame handFrame;

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
    this.transposition = Transposition.concert,
    this.alignment = AlignmentProfile.bowedStrings,
    this.handFrame = HandFrame.fourth,
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
        transposition: transposition,
        alignment: alignment,
        handFrame: handFrame,
      );

  /// Whether the instrument is fingered on strings: the string fingering,
  /// its colours and lanes, and the open-or-4th choice exist only then.
  bool get hasStrings => openMidi.isNotEmpty;

  /// A wind's fingering chart, keyed on written pitch: the hole diagram, the
  /// side panel and the colour lane read it. Null for the strings.
  HoleFingeringChart? get fingeringChart => switch (id) {
        'recorder' => HoleFingeringChart.sopranoBaroque,
        'irishFlute' => HoleFingeringChart.irishFluteKeyless,
        _ => null,
      };

  /// Whether [midi] is both an open string and a 4th finger on the string
  /// below: the notes where the fingering is a choice (violin D4, A4, E5;
  /// viola G3, D4, A4). Never without strings, and never on a cello, whose
  /// 4th finger stops a fourth short of the next string ([HandFrame]).
  bool hasFourthFingerChoice(int midi) =>
      hasStrings &&
      handFrame == HandFrame.fourth &&
      midi != openMidi.first &&
      openMidi.contains(midi);

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
    alignment: AlignmentProfile.bowedStrings,
  );

  /// Tuned like the violin (G D A E), read in treble at sounding pitch. Its
  /// range here is the violin's first position, which is also what the fret
  /// numbers stay within.
  ///
  /// It aligns with the violin's [AlignmentProfile] for now. Its range is
  /// the violin's, so the band fits; but a plucked course decays where a bow
  /// sustains, which might want a shorter `ringSeconds` and a heavier onset
  /// weight. There is no mandolin recording among the alignment fixtures to
  /// measure that on, and tuning it without one would be guessing.
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
  ///
  /// Its open C (130.8 Hz) is below the violin's 180 Hz chroma floor, so the
  /// band starts at 120 Hz: the C string's fundamental is heard, with a
  /// margin for a flat string. Everything else in its alignment is the
  /// violin's.
  static const viola = InstrumentProfile(
    id: 'viola',
    displayName: 'Viola',
    layerId: 'viola',
    clef: altoClef,
    lowestMidi: 48,
    highestMidi: 76,
    strings: ['C', 'G', 'D', 'A'],
    openMidi: [48, 55, 62, 69],
    alignment: AlignmentProfile(minFrequencyHz: 120),
  );

  /// An octave below the viola (C G D A), read in bass clef. First position
  /// runs C2 to D4, the 4th finger on the A string; its fingering is its own
  /// ([HandFrame.minorThird]).
  ///
  /// Its alignment band starts at 120 Hz, like the viola's, not under its
  /// open C (65 Hz). The chroma's bins are about 11 Hz wide, wider than a
  /// semitone below about 180 Hz, so a fundamental down there smears across
  /// pitch classes; a cello note's 2nd harmonic, the same pitch class an
  /// octave up, is at 130.8 Hz or more and so always in the band. A first
  /// guess, with no cello recording to tune it on.
  static const cello = InstrumentProfile(
    id: 'cello',
    displayName: 'Cello',
    layerId: 'cello',
    clef: bassClef,
    lowestMidi: 36,
    highestMidi: 62,
    strings: ['C', 'G', 'D', 'A'],
    openMidi: [36, 43, 50, 57],
    alignment: AlignmentProfile(minFrequencyHz: 120),
    handFrame: HandFrame.minorThird,
  );

  /// The soprano (descant) recorder: read in treble, written C4 to D6, and
  /// sounding an octave higher (C5 to D7), as its parts are written
  /// ([Transposition.octaveUp]). No strings.
  ///
  /// A violin tune (concert pitch, treble) is shown to it as a written part:
  /// moved an octave down for the transposition, then back up by whole
  /// octaves into the written range (`InstrumentView`). A first-position
  /// violin tune therefore reads exactly as the violin part does and sounds
  /// an octave above it; one that dips onto the G string reads an octave
  /// higher. Playback and the aligner's reference both use the sounding
  /// pitch ([transposition]).
  ///
  /// Its [AlignmentProfile] is a first guess, with no recorder recording to
  /// measure it on: almost no ring (a wind stops when the breath does), a
  /// band from 400 Hz (the lowest sounding note is C5, 523 Hz, with room for
  /// a flat one) up to 4 kHz (the top, D7, is about 2350 Hz). Onset weight is
  /// the violin's.
  static const recorder = InstrumentProfile(
    id: 'recorder',
    displayName: 'Recorder',
    layerId: 'recorder',
    clef: trebleClef,
    lowestMidi: 60,
    highestMidi: 86,
    strings: [],
    openMidi: [],
    transposition: Transposition.octaveUp,
    alignment: AlignmentProfile(
        minFrequencyHz: 400, maxFrequencyHz: 4000, ringSeconds: 0.15),
  );

  /// The keyless six-hole Irish flute in D (docs/plan.md §7.5): treble, at
  /// sounding pitch, D4 to D6, the two octaves a beginner plays and the
  /// third's D. No strings. A violin tune that dips below D4 is moved up an
  /// octave (`InstrumentView`), as for the recorder.
  ///
  /// Its [AlignmentProfile] is a first guess like the recorder's, with no
  /// flute recording to measure it on: little ring, a band from 250 Hz (D4
  /// is 294 Hz, with room for a flat one) to 4 kHz, over the top D's
  /// 1175 Hz and the breathy tone's upper partials.
  static const irishFlute = InstrumentProfile(
    id: 'irishFlute',
    displayName: 'Irish flute',
    layerId: 'irishFlute',
    clef: trebleClef,
    lowestMidi: 62,
    highestMidi: 86,
    strings: [],
    openMidi: [],
    alignment: AlignmentProfile(
        minFrequencyHz: 250, maxFrequencyHz: 4000, ringSeconds: 0.15),
  );
}

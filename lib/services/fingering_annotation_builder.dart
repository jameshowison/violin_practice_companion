import '../models/fingering_density.dart';
import '../models/gdae_tuning.dart';
import '../models/note_event.dart';
import '../models/note_number_mode.dart';
import '../models/parsed_piece.dart';
import '../models/section.dart';
import '../models/string_label_style.dart';

/// One fingering label to draw in the channel above a system.
///
/// Coordinates are the engraved measure INDEX plus the positional note index
/// within it, which is exactly what `EngravedScore.noteAt` takes — the same
/// (index, note) addressing the section wash and the chord lane already use to
/// find a notehead's x.
typedef FingeringAnnotation = ({
  int measureIndex,
  int noteIndex,
  String label, // '2L' with colours on, 'A2L' with them off — never rewritten
  String? string, // 'G'|'D'|'A'|'E', picks the chip fill; null = unknown
});

/// One unbroken span of playing on a single string, for the underline style.
///
/// Note-level edges in engraved-index space, exactly like [ChordRunRegion] — a
/// string run and a chord run are the same object (a value that holds until it
/// changes), so this is resolved by the same [resolveSectionRanges] and drawn by
/// the same per-system geometry.
typedef StringRunRegion = ({
  int startMeasureIndex,
  int startNote,
  int endMeasureIndex,
  int endNote, // EXCLUSIVE; -1 = to the end of endMeasureIndex
  String string,
});

/// Fret numbers that reach two digits would need a wider chip than the channel's
/// square-ish minimum assumes. In GDAE first position they can't: the highest
/// fret [GdaeTuning] will produce for a fingered note is 7 (the 4th finger on a
/// string, under [FretStyle.matchFingering]).
const int maxFirstPositionFret = 7;

/// The fingering labels to draw, in score order, after density filtering.
///
/// This replaces what [FingeringXmlInjector] does for the OSMD fallback: under
/// the native renderer the labels are NOT engraved into the MusicXML (Verovio
/// would place each one against its notehead, which is what made them ride up
/// and down with pitch and inflate the measure bbox that the chord lane's
/// whitespace is measured from). Drawing them in a lane instead makes the level
/// flat by construction and hands the vertical budget back to the chord lane.
///
/// [measureNumbers] is the engraved order (index → measure number), matching
/// [chordRunRegions].
/// [numberMode] swaps the violin finger for the mandolin fret; [fretStyle] then
/// decides which string carries it (and so, since the colour follows the string,
/// whether the chips keep their colours). Both are shared with the tab staff.
///
/// Note that the number mode changes only WHAT each chip says, never WHICH notes
/// get one: the density rules stay keyed to the violin fingering throughout (see
/// [showFingering]). That is deliberate — the signals they score are about the
/// hand (a string crossing, a stretch to the 4th finger, a low 2nd), and those
/// facts don't change because the label is now expressed as a fret. It also means
/// switching the number mode never makes labels appear or disappear.
List<FingeringAnnotation> fingeringAnnotations(
  List<int> measureNumbers,
  ParsedPiece parsed, {
  required FingeringDensity density,
  required FingeringDensityPolicy policy,
  required bool colourByString,
  required StringLabelStyle stringLabelStyle,
  NoteNumberMode numberMode = NoteNumberMode.violinFingering,
  FretStyle fretStyle = FretStyle.openStrings,
}) {
  final out = <FingeringAnnotation>[];

  // Rolling context. All three track the previous note in the MUSIC, not the
  // previous note that got a label — so what shows at one density level can
  // never depend on what showed at another, and `onChange` puts the string
  // letter in the same place at every level. (A string change is crucial under
  // both policies, so it survives every level and the letter can't go missing.)
  NoteEvent? prev;
  String? prevString;
  var afterRest = false;
  var isFirstNote = true;

  for (final m in parsed.measures) {
    final measureIndex = measureNumbers.indexOf(m.number);
    var isMeasureStart = true;

    for (var j = 0; j < m.notes.length; j++) {
      final note = m.notes[j];

      if (note.isRest) {
        afterRest = true;
        continue;
      }

      final hasFingering =
          note.fingerString != null && note.fingerNumber != null;

      // A chord member sounds at the primary note's onset, so its chip would
      // land on the same x. Skip it — but it still consumed a note index in
      // both the parsed model and the engraved anchors, so the indices stay
      // aligned either way.
      final drawable = hasFingering && !note.isChord && measureIndex >= 0;

      // What this note's chip would say and sit on. Resolved for every fingered
      // note, drawn or not, so `prevString` (the `onChange` letter) tracks the
      // music rather than the surviving labels.
      final shown = hasFingering
          ? shownNumber(note, numberMode, fretStyle)
          : (string: null, number: '');

      if (drawable) {
        final c = (
          note: note,
          prev: prev,
          isFirstNote: isFirstNote,
          isMeasureStart: isMeasureStart,
          afterRest: afterRest,
        );
        if (showFingering(c, density: density, policy: policy)) {
          out.add((
            measureIndex: measureIndex,
            noteIndex: j,
            label: _label(
                shown, colourByString, stringLabelStyle, prevString),
            string: shown.string,
          ));
        }
      }

      if (hasFingering) prevString = shown.string;
      prev = note;
      isFirstNote = false;
      isMeasureStart = false;
      afterRest = false;
    }
  }

  return out;
}

/// One region per unbroken run of playing on the same string, over the WHOLE
/// piece — independent of [FingeringDensity], which is the point.
///
/// The underline is a string track, not a decoration on a label: it answers
/// "which string am I on right now?" for every note, including the ones whose
/// number the density filter dropped. At "Least" that is most of them, so tying
/// the run to the surviving labels would leave the colour cue in tatters exactly
/// where it does the most work.
///
/// Rests do NOT break a run. A rest is the bow lifting, not the hand moving; the
/// next note on the same string is a continuation, and breaking there would imply
/// a change that didn't happen.
///
/// [numberMode] and [fretStyle] matter because they can change which string a
/// note is played on — under [FretStyle.openStrings] a run can end where the
/// fingering alone would have continued. Resolved through the same [_shown] the
/// labels use, so the runs and the chips can never disagree.
List<StringRunRegion> stringRunRegions(
  List<int> measureNumbers,
  ParsedPiece parsed, {
  NoteNumberMode numberMode = NoteNumberMode.violinFingering,
  FretStyle fretStyle = FretStyle.openStrings,
}) {
  // A marker wherever the string changes — the same "value that holds until the
  // next marker" shape as a chord run, so the boundary resolution is delegated
  // rather than re-derived. See [chordRunRegions], which does this for chords.
  final markers = <Section>[];
  String? prev;
  for (final m in parsed.measures) {
    for (var j = 0; j < m.notes.length; j++) {
      final note = m.notes[j];
      if (note.isRest) continue;
      if (note.fingerString == null || note.fingerNumber == null) continue;
      final s = shownNumber(note, numberMode, fretStyle).string;
      if (s == null || s == prev) continue;
      markers.add(Section(label: s, startMeasure: m.number, startNote: j));
      prev = s;
    }
  }
  if (markers.isEmpty) return const [];

  final out = <StringRunRegion>[];
  for (final r in resolveSectionRanges(markers, parsed.measures)) {
    final startIdx = measureNumbers.indexOf(r.startMeasure);
    final endIdx = measureNumbers.indexOf(r.endMeasure);
    if (startIdx < 0 || endIdx < 0) continue;
    out.add((
      startMeasureIndex: startIdx,
      startNote: r.startNote,
      endMeasureIndex: endIdx,
      endNote: r.endNote,
      string: r.label,
    ));
  }
  return out;
}

/// The string a note's chip sits on and the number it shows.
///
/// In fingering mode that is simply the fingering, verbatim. In fret mode both
/// come from [GdaeTuning.resolve], so under [FretStyle.openStrings] the string
/// can differ from the violin fingering's — which is exactly the point of that
/// option, and why the chip colour moves with it.
///
/// Under [FretStyle.matchFingering] the fret is whatever distance the note sits
/// above the fingering's own string, and that is reported as-is: a piece whose
/// `fingerString` disagrees with its `midiNumber` will show a fret above 7, or a
/// negative one. Deliberately not clamped — the fingering table can't produce
/// such a pair, so seeing one means the data is wrong and hiding it would only
/// make that harder to notice.
///
/// Public (not `_shown`) so other views of a single note — e.g. the measure
/// edit screen's note cards — resolve the same mode/style switch instead of
/// falling back to the raw violin fingering.
({String? string, String number}) shownNumber(
  NoteEvent note,
  NoteNumberMode numberMode,
  FretStyle fretStyle,
) {
  if (numberMode == NoteNumberMode.violinFingering) {
    return (string: note.fingerString, number: note.fingerNumber!);
  }
  final at = GdaeTuning.resolve(
    note.midiNumber,
    fingerString: note.fingerString,
    preferOpenFrets: fretStyle == FretStyle.openStrings,
  );
  return (string: at.string, number: '${at.fret}');
}

/// The label text for a chip showing [shown].
///
/// With colours on the string letter is dropped — the chip's fill carries it,
/// which is the whole point of colouring them. With colours off this is the
/// [StringLabelStyle] logic the XML injector applies, so turning colours off
/// gives back exactly the labels the view showed before.
///
/// In fingering mode the number is emitted VERBATIM, L/H suffix intact. It is
/// meaningful data (a low 2 and a 2 are different notes) and must never be
/// stripped or rewritten as ♭/♯ — see CLAUDE.md. A fret needs no such suffix: it
/// names the exact semitone already.
String _label(
  ({String? string, String number}) shown,
  bool colourByString,
  StringLabelStyle style,
  String? prevString,
) {
  if (colourByString) return shown.number;
  final letter = shown.string ?? '';
  final strPart = switch (style) {
    StringLabelStyle.always => letter,
    StringLabelStyle.onChange => shown.string != prevString ? letter : '',
    StringLabelStyle.never => '',
  };
  return '$strPart${shown.number}';
}

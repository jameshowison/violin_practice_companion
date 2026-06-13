import 'duration_step.dart';
import 'note_event.dart';

class Measure {
  final int number;
  final List<NoteEvent> notes;
  final List<NoteEvent> hiddenLeadNotes;

  /// Repeat barlines on this measure's boundaries, parsed from MusicXML
  /// `<barline><repeat direction="forward|backward"/>`. [repeatStart] is the
  /// forward repeat on the left edge (`|:`); [repeatEnd] is the backward repeat
  /// on the right edge (`:|`, drawn as the doubled light-heavy barline).
  final bool repeatStart;
  final bool repeatEnd;

  const Measure({
    required this.number,
    required this.notes,
    this.hiddenLeadNotes = const [],
    this.repeatStart = false,
    this.repeatEnd = false,
  });

  /// Returns a copy with replaced [notes], carrying the measure number, hidden
  /// pickup rests, and repeat flags through unless explicitly overridden. The
  /// jianpu/fingering processors rebuild measures via this method, so the repeat
  /// flags must survive to `parsedPieceProvider`'s output.
  Measure copyWithNotes(List<NoteEvent> notes,
          {bool? repeatStart, bool? repeatEnd}) =>
      Measure(
        number: number,
        notes: notes,
        hiddenLeadNotes: hiddenLeadNotes,
        repeatStart: repeatStart ?? this.repeatStart,
        repeatEnd: repeatEnd ?? this.repeatEnd,
      );

  /// True when this measure's visible notes don't sum to the expected number of
  /// beats — a common OMR symptom (a note split in two, or two merged). Pickup
  /// measures (number 0) are intentionally never flagged, since they are
  /// expected to be short. Compares in 32nd-note units to stay integer-exact.
  bool isDurationMismatch(int beatsPerMeasure, int beatType) {
    if (number == 0) return false;
    final expected = beatsPerMeasure * 32 ~/ beatType;
    return actualUnits != expected;
  }

  /// Sum of this measure's visible-note durations in 32nd-note units.
  int get actualUnits => notes.fold<int>(
      0, (sum, n) => sum + thirtySecondUnits(n.noteValue, n.dotted));

  /// True when this measure is shorter than a full bar — the hallmark of a
  /// pickup/anacrusis.
  bool isShort(int beatsPerMeasure, int beatType) =>
      actualUnits < beatsPerMeasure * 32 ~/ beatType;
}

class ParsedPiece {
  final String keySignature;
  final int keyFifths;
  final KeyMode keyMode;
  final List<Measure> measures;

  /// Timing metadata from the first `<attributes>` block. Needed to generate
  /// `<duration>` values when serializing edits and to validate beat counts.
  /// Defaults match a 4/4 score with one division per quarter note.
  final int divisions;
  final int beatsPerMeasure;
  final int beatType;

  const ParsedPiece({
    required this.keySignature,
    required this.keyFifths,
    required this.keyMode,
    required this.measures,
    this.divisions = 1,
    this.beatsPerMeasure = 4,
    this.beatType = 4,
  });

  ParsedPiece copyWithMeasures(List<Measure> measures) => ParsedPiece(
        keySignature: keySignature,
        keyFifths: keyFifths,
        keyMode: keyMode,
        measures: measures,
        divisions: divisions,
        beatsPerMeasure: beatsPerMeasure,
        beatType: beatType,
      );

  List<NoteEvent> get allNotes =>
      measures.expand((m) => m.notes).toList(growable: false);

  /// Document-measure indices in performance order, honoring simple forward/
  /// backward repeats. A forward repeat ([Measure.repeatStart]) sets the return
  /// point; a backward repeat ([Measure.repeatEnd]), the first time it's
  /// reached, jumps back to that return point once (defaulting to the piece
  /// start if no forward repeat preceded it), then continues past on the second
  /// arrival. Nested repeats and voltas/endings are out of scope. With no
  /// repeats the result is the identity `[0, 1, … n-1]`.
  ///
  /// Shared by MIDI generation (audio order) and the section-organized layout /
  /// staff unfold (so a `|: A :|` span shows up as two `A`s on the staff).
  static List<int> performanceOrder(List<Measure> measures) {
    final order = <int>[];
    final endRepeatTaken = <int>{};
    var returnIndex = 0;
    var i = 0;
    var guard = 0;
    while (i < measures.length) {
      if (++guard > 1000000) break; // backstop against a malformed loop
      final m = measures[i];
      if (m.repeatStart) returnIndex = i;
      order.add(i);
      if (m.repeatEnd && !endRepeatTaken.contains(i)) {
        endRepeatTaken.add(i);
        i = returnIndex;
        continue;
      }
      i++;
    }
    return order;
  }

  /// Measure numbers whose visible notes don't total the expected beat count.
  /// A short FIRST measure is treated as a pickup/anacrusis and never flagged,
  /// even when OMR output numbered it 1 instead of 0 (so the
  /// `number == 0` guard in [Measure.isDurationMismatch] wouldn't catch it).
  Set<int> get flaggedMeasureNumbers {
    final flagged = <int>{};
    for (var i = 0; i < measures.length; i++) {
      final m = measures[i];
      if (i == 0 && m.isShort(beatsPerMeasure, beatType)) continue;
      if (m.isDurationMismatch(beatsPerMeasure, beatType)) flagged.add(m.number);
    }
    return flagged;
  }
}

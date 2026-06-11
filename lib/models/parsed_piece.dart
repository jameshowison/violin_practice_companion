import 'duration_step.dart';
import 'note_event.dart';

class Measure {
  final int number;
  final List<NoteEvent> notes;
  final List<NoteEvent> hiddenLeadNotes;

  const Measure({required this.number, required this.notes, this.hiddenLeadNotes = const []});

  Measure copyWithNotes(List<NoteEvent> notes) =>
      Measure(number: number, notes: notes, hiddenLeadNotes: hiddenLeadNotes);

  /// True when this measure's visible notes don't sum to the expected number of
  /// beats — a common OMR symptom (a note split in two, or two merged). Pickup
  /// measures (number 0) are intentionally never flagged, since they are
  /// expected to be short. Compares in 32nd-note units to stay integer-exact.
  bool isDurationMismatch(int beatsPerMeasure, int beatType) {
    if (number == 0) return false;
    final expected = beatsPerMeasure * 32 ~/ beatType;
    final actual = notes.fold<int>(
        0, (sum, n) => sum + thirtySecondUnits(n.noteValue, n.dotted));
    return actual != expected;
  }
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

  /// Measure numbers whose visible notes don't total the expected beat count.
  Set<int> get flaggedMeasureNumbers => {
        for (final m in measures)
          if (m.isDurationMismatch(beatsPerMeasure, beatType)) m.number,
      };
}

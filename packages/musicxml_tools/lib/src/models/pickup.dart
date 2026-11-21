import 'duration_step.dart';
import 'note_event.dart';
import 'parsed_piece.dart';

/// How much of the count's last bar the pickup at [measure] already fills, in
/// 32nd-note units. 0 for a full bar, and for a null measure.
///
/// The measure's hidden lead rests count towards its length: MusicXML pads an
/// anacrusis with `print-object="no"` rests and the audio clock starts at the
/// BARLINE, so a pickup written as "hidden eighth rest + eighth note" occupies a
/// whole beat of the bar even though only half of it sounds — and the count has to
/// yield that whole beat.
///
/// A start part-way into a full bar, at note [fromNote] (a section that begins
/// on its lead-in), is a pickup too: what's left of the bar from that note.
int pickupUnitsOf(
  Measure? measure, {
  required int beatsPerMeasure,
  required int beatType,
  int fromNote = 0,
}) {
  if (measure == null || beatsPerMeasure <= 0 || beatType <= 0) return 0;
  final barUnits = beatsPerMeasure * 32 ~/ beatType;
  var units = 0;
  if (fromNote > 0 && fromNote < measure.notes.length) {
    units = unitsOf(measure.notes.skip(fromNote));
  } else {
    units = measure.actualUnits;
    for (final hidden in measure.hiddenLeadNotes) {
      units += thirtySecondUnits(hidden.noteValue, hidden.dotted);
    }
  }
  if (units <= 0 || units >= barUnits) return 0;
  return units;
}

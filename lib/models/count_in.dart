import 'duration_step.dart';
import 'parsed_piece.dart';

/// The count-off before playback starts, so there is time to get the instrument
/// up and the bow on the string before the first note sounds.
///
/// The count spans **whole bars, minus the pickup**. That one rule is what makes
/// the numbers mean something: they are the bar's own beats, so a tune whose
/// anacrusis is beat four is counted "1 2 3" and the pickup lands on its real 4.
/// A flat "three beats" couldn't promise that, and a flat "one bar" would count
/// straight over the note you are about to play.
///
/// Everything here is measured in **32nd-note units** (the app's exact duration
/// currency — see [thirtySecondUnits]), so a sub-beat pickup needs no rounding:
/// the last counted beat is simply cut short by it.

/// Never fewer than three counted beats: two is not enough to hear the pulse, and
/// hearing the pulse is half of what the count is for. When a bar can't supply
/// three (2/4, or 4/4 less a two-beat pickup), the count takes another whole bar
/// rather than breaking the metre.
const countInMinBeats = 3;

/// The longest minimum the preference offers. Eight beats is two bars of 4/4,
/// which is as long as a count-off ever usefully gets.
const countInMaxBeats = 8;

/// A count-in in progress, for the display.
///
/// [labels] is the whole sequence as bar-relative beat numbers (`[1,2,3]`, or
/// `[1,2,3,4,1,2]` for a count that runs two bars), and [index] is the position
/// in it being counted now. [startMeasure] is the measure playback will begin on,
/// which is what anchors the display to a system (see `StaffViewVerovio`) — a
/// count-in for a practice range starting at bar 30 must not appear over bar 1,
/// eight systems away.
typedef CountInTick = ({List<int> labels, int index, int startMeasure});

/// A resolved count-off: what to show and exactly how long it lasts.
///
/// [totalUnits] is the count's full length and [unit] one counted beat, both in
/// 32nd-note units. `labels.length * unit` may EXCEED [totalUnits] — that is the
/// sub-beat pickup case, where the final number gets less than a full beat before
/// the music starts.
typedef CountInPlan = ({List<int> labels, int totalUnits, int unit});

/// How a bar of this meter is counted: one counted beat ([unit], in 32nd-note
/// units) and how many of them make a bar ([perBar]).
///
/// A table rather than `32 ~/ beatType`, because meters don't all count their
/// denominator. A jig in 6/8 is counted in two dotted quarters, not six eighths —
/// counting "1 2 3 4 5 6" at jig tempo is both wrong and unusable. Cut-common and
/// its relatives count halves. Anything not listed falls back to the denominator,
/// which is right for every x/4 and for the odd meters (5/4, 7/8).
({int unit, int perBar}) barCounting(int beatsPerMeasure, int beatType) {
  const dottedQuarter = 12;
  // Compound meters: the beat is the dotted note, three denominators long.
  if (beatType == 8 && beatsPerMeasure % 3 == 0 && beatsPerMeasure >= 6) {
    return (unit: dottedQuarter, perBar: beatsPerMeasure ~/ 3);
  }
  final unit = beatType <= 0 ? 8 : 32 ~/ beatType;
  return (unit: unit < 1 ? 1 : unit, perBar: beatsPerMeasure < 1 ? 1 : beatsPerMeasure);
}

/// How much of the count's last bar the pickup at [measure] already fills, in
/// 32nd-note units. 0 for a full bar, and for a null measure.
///
/// The measure's hidden lead rests count towards its length: MusicXML pads an
/// anacrusis with `print-object="no"` rests and the audio clock starts at the
/// BARLINE, so a pickup written as "hidden eighth rest + eighth note" occupies a
/// whole beat of the bar even though only half of it sounds — and the count has to
/// yield that whole beat.
int pickupUnitsOf(
  Measure? measure, {
  required int beatsPerMeasure,
  required int beatType,
}) {
  if (measure == null || beatsPerMeasure <= 0 || beatType <= 0) return 0;
  final barUnits = beatsPerMeasure * 32 ~/ beatType;
  var units = measure.actualUnits;
  for (final hidden in measure.hiddenLeadNotes) {
    units += thirtySecondUnits(hidden.noteValue, hidden.dotted);
  }
  if (units <= 0 || units >= barUnits) return 0;
  return units;
}

/// The count-off to give before a start on a measure whose pickup is
/// [pickupUnits] long, or null when there is to be no count at all.
///
/// [minBeats] sizes the count in BARS: enough whole bars to cover that many
/// beats (so 8 in 4/4 means two bars, coming out at seven after a one-beat
/// pickup — the count ends on the barline, never part-way through one). 0 turns
/// the count off.
///
/// [countInMinBeats] is then a hard floor on what's left: a bar that can't supply
/// three counted beats after the pickup takes another one, which is what keeps
/// 2/4, and 4/4 with a half-bar anacrusis, countable.
///
/// Capped at eight bars, which only bites on nonsense inputs.
CountInPlan? countInPlan({
  required int beatsPerMeasure,
  required int beatType,
  int minBeats = countInMinBeats,
  int pickupUnits = 0,
}) {
  if (minBeats <= 0) return null;
  final target = minBeats < countInMinBeats ? countInMinBeats : minBeats;
  final (unit: unit, perBar: perBar) =
      barCounting(beatsPerMeasure, beatType);
  final barUnits = unit * perBar;
  if (barUnits <= 0) return null;
  final pickup = pickupUnits.clamp(0, barUnits - 1);

  // Whole bars covering the requested minimum, then grown while the pickup eats
  // the count below the floor.
  var bars = (target + perBar - 1) ~/ perBar;
  if (bars < 1) bars = 1;
  var totalUnits = bars * barUnits - pickup;
  while (bars < 8 && (totalUnits + unit - 1) ~/ unit < countInMinBeats) {
    bars++;
    totalUnits = bars * barUnits - pickup;
  }

  // One label per counted beat that starts before the music does. The count
  // begins on a downbeat by construction (it spans whole bars back from the
  // pickup), so a beat's position within its bar is just `t % barUnits`.
  final labels = <int>[
    for (var t = 0; t < totalUnits; t += unit) (t % barUnits) ~/ unit + 1,
  ];
  if (labels.isEmpty) return null;
  return (labels: labels, totalUnits: totalUnits, unit: unit);
}

/// Seconds per 32nd-note unit at [bpm].
///
/// [bpm] is a QUARTER-note tempo (see `MidiGenerator`, where one quarter is
/// `ticksPerQuarterNote` ticks), and a quarter is 8 units.
double countInUnitSeconds(int bpm) => bpm <= 0 ? 0 : (60.0 / bpm) / 8.0;

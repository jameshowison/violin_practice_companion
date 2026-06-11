import 'note_event.dart';

/// A note's rhythmic value as a single `(NoteValue, dotted)` pair, plus an
/// ordered shortest→longest list that the measure editor's duration control
/// cycles through. Combining the dot into the ordering means ◀/▶ map directly
/// to "shorter/longer" without a separate dot toggle.
class DurationStep {
  final NoteValue value;
  final bool dotted;

  const DurationStep(this.value, this.dotted);

  /// Shortest → longest. Each note value is followed by its dotted form.
  static const List<DurationStep> ordered = [
    DurationStep(NoteValue.sixteenth, false),
    DurationStep(NoteValue.sixteenth, true),
    DurationStep(NoteValue.eighth, false),
    DurationStep(NoteValue.eighth, true),
    DurationStep(NoteValue.quarter, false),
    DurationStep(NoteValue.quarter, true),
    DurationStep(NoteValue.half, false),
    DurationStep(NoteValue.half, true),
    DurationStep(NoteValue.whole, false),
    DurationStep(NoteValue.whole, true),
  ];

  static int _indexOf(NoteValue value, bool dotted) =>
      ordered.indexWhere((d) => d.value == value && d.dotted == dotted);

  /// One step longer (clamped at whole•).
  static DurationStep next(NoteValue value, bool dotted) {
    final i = _indexOf(value, dotted);
    return ordered[(i + 1).clamp(0, ordered.length - 1)];
  }

  /// One step shorter (clamped at 16th).
  static DurationStep previous(NoteValue value, bool dotted) {
    final i = _indexOf(value, dotted);
    return ordered[(i - 1).clamp(0, ordered.length - 1)];
  }

  /// Human-readable label, e.g. "quarter note" / "dotted eighth note".
  String get label {
    const names = {
      NoteValue.whole: 'whole',
      NoteValue.half: 'half',
      NoteValue.quarter: 'quarter',
      NoteValue.eighth: 'eighth',
      NoteValue.sixteenth: 'sixteenth',
    };
    return '${dotted ? 'dotted ' : ''}${names[value]} note';
  }

  @override
  bool operator ==(Object other) =>
      other is DurationStep && other.value == value && other.dotted == dotted;

  @override
  int get hashCode => Object.hash(value, dotted);
}

/// Duration of a `(NoteValue, dotted)` pair in 32nd-note units. Integer for
/// every value in [DurationStep.ordered] (a dotted sixteenth is 3 units), so
/// beat-totals and `<duration>` values can be computed without floating-point
/// rounding. A quarter note is 8 units.
int thirtySecondUnits(NoteValue value, bool dotted) {
  final base = switch (value) {
    NoteValue.whole => 32,
    NoteValue.half => 16,
    NoteValue.quarter => 8,
    NoteValue.eighth => 4,
    NoteValue.sixteenth => 2,
  };
  return dotted ? base + base ~/ 2 : base;
}

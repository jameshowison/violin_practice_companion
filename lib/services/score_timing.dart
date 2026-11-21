/// One note of a score laid out in time: when it starts and stops sounding,
/// in seconds from the start of the performance, and its MIDI pitch.
abstract interface class TimedNote {
  double get onsetSeconds;
  double get offsetSeconds;
  int get midiNote;
}

/// A score laid out in time at one tempo, in performance order (repeats
/// expanded): what the aligner needs to know about a piece.
abstract interface class TimedScore {
  /// Sorted by onset.
  List<TimedNote> get notes;

  /// Index i is the onset of the i-th performed measure.
  List<double> get measureOnsetSeconds;

  /// The written number of each performed measure, parallel to
  /// [measureOnsetSeconds].
  List<int> get measureNumbers;

  double get totalDurationSeconds;
}

/// How a score of type [S] is laid out in time at [bpm] quarter notes per
/// minute. At 60 bpm a quarter lasts one second, so
/// `timing(score, 60).totalDurationSeconds` is the score's length in beats.
typedef ScoreTiming<S> = TimedScore Function(S score, int bpm);

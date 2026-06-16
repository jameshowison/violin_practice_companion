/// One section *occurrence* in display order. Used in two distinct shapes:
///
///  * **Folded layout runs** ([PieceLayout.runs]) span a contiguous range of
///    [rows]; each section appears once (A, B, C…) and a literal restatement
///    yields a second same-label run. These drive the inline jianpu/fingering
///    section headers.
///  * **Unfolded minimap runs** (`sectionRuns`) span a contiguous slice of the
///    *performance order* ([perfStart]..[perfEnd]); a `|: A :|` repeat yields
///    two A runs. These drive the right-hand minimap and pass-accurate playback
///    highlighting. Row fields are unused here ([rowStart]/[rowCount] = 0).
///
/// Repeated occurrences sharing a label are distinguished by
/// [passIndex]/[passCount]. [firstMeasure]/[lastMeasure] are document measure
/// numbers (used to set a practice [MeasureSelection] / navigate on tap).
class SectionRun {
  final String label;
  final int passIndex; // 0-based occurrence among same-label runs
  final int passCount; // total runs sharing this label
  final int rowStart; // first row index into PieceLayout.rows (folded runs only)
  final int rowCount;
  final int firstMeasure;
  final int lastMeasure;

  /// Performance-order slice this run occupies (unfolded minimap runs only):
  /// indices into [ParsedPiece.performanceOrder]. [perfEnd] is exclusive.
  /// `-1` when not applicable (folded layout runs).
  final int perfStart;
  final int perfEnd;

  const SectionRun({
    required this.label,
    required this.passIndex,
    required this.passCount,
    this.rowStart = 0,
    this.rowCount = 0,
    required this.firstMeasure,
    required this.lastMeasure,
    this.perfStart = -1,
    this.perfEnd = -1,
  });

  int get rowEnd => rowStart + rowCount; // exclusive

  /// True when [performanceIndex] (a position in the performance order) falls in
  /// this run's slice — used by the minimap to light the exact playing pass.
  bool containsPerf(int performanceIndex) =>
      perfStart >= 0 && performanceIndex >= perfStart && performanceIndex < perfEnd;

  /// Title shown in headers/minimap: bare label when unique, numbered pass when
  /// the section repeats — e.g. `A` vs `A (1 of 2)`.
  String get title =>
      passCount > 1 ? '$label (${passIndex + 1} of $passCount)' : label;

  SectionRun copyWith({int? passIndex, int? passCount}) => SectionRun(
        label: label,
        passIndex: passIndex ?? this.passIndex,
        passCount: passCount ?? this.passCount,
        rowStart: rowStart,
        rowCount: rowCount,
        firstMeasure: firstMeasure,
        lastMeasure: lastMeasure,
        perfStart: perfStart,
        perfEnd: perfEnd,
      );
}

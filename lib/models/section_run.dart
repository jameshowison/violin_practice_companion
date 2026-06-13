/// One section *occurrence* in display order, spanning a contiguous range of
/// [PieceLayout] rows. In folded layout there is one run per section (A, B, C…);
/// in section-organized (ABAA) layout a repeated section yields multiple runs
/// sharing a label (A, A, B, C, C…), distinguished by [passIndex]/[passCount].
///
/// Drives the inline section headers, the right-hand minimap, and section
/// navigation. [firstMeasure]/[lastMeasure] are document measure numbers (used
/// to set a practice [MeasureSelection] on tap).
class SectionRun {
  final String label;
  final int passIndex; // 0-based occurrence among same-label runs
  final int passCount; // total runs sharing this label
  final int rowStart; // first row index into PieceLayout.rows
  final int rowCount;
  final int firstMeasure;
  final int lastMeasure;

  const SectionRun({
    required this.label,
    required this.passIndex,
    required this.passCount,
    required this.rowStart,
    required this.rowCount,
    required this.firstMeasure,
    required this.lastMeasure,
  });

  int get rowEnd => rowStart + rowCount; // exclusive

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
      );
}

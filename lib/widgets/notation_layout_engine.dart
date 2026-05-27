import 'package:flutter/material.dart';
import '../models/parsed_piece.dart';

class NotationLayout {
  static const double cellWidth = 36;
  static const double rowHeight = 56;
  static const double barlineWidth = 2;

  static double measureWidth(Measure m) =>
      m.notes.fold(0.0, (sum, _) => sum + cellWidth);

  static double rowWidth(List<Measure> row) =>
      row.fold(0.0, (sum, m) => sum + measureWidth(m)) +
      (row.length - 1) * barlineWidth;
}

abstract class NotationPainter extends CustomPainter {
  final List<Measure> measures;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;

  NotationPainter({
    required this.measures,
    required this.selectedMeasures,
    required this.sectionLabels,
  });

  @override
  bool shouldRepaint(covariant NotationPainter old) =>
      old.measures != measures ||
      old.selectedMeasures != selectedMeasures ||
      old.sectionLabels != sectionLabels;
}

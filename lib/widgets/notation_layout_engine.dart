import 'package:flutter/material.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';

class NotationLayout {
  static const double cellWidth = 36;
  static const double rowHeight = 56;
  static const double barlineWidth = 2;

  static double noteWidth(NoteEvent n) {
    switch (n.noteValue) {
      case NoteValue.whole: return cellWidth * 4;
      case NoteValue.half:  return n.dotted ? cellWidth * 3 : cellWidth * 2;
      default:              return cellWidth;
    }
  }

  static double measureWidth(Measure m) =>
      m.notes.fold(0.0, (sum, n) => sum + noteWidth(n));

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

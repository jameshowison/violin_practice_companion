import 'package:xml/xml.dart';
import 'parsed_piece.dart';
import 'section.dart';

/// Returns the number of measures per row appropriate for a given screen width.
/// Breakpoints are in logical pixels.
int measuresPerRowForWidth(double widthPx) {
  if (widthPx >= 600) return 4;
  return 2;
}

/// Pre-computed row layout for a piece. A single instance is derived once
/// (in [pieceLayoutProvider]) and shared by all notation views.
class PieceLayout {
  final List<List<Measure>> rows;

  const PieceLayout(this.rows);

  /// Computes rows: [measuresPerRow] measures per row, with section
  /// boundaries always forcing a new row.
  factory PieceLayout.compute(
    List<Measure> measures,
    List<Section> sections, {
    int measuresPerRow = 4,
  }) {
    final sectionStarts = {for (final s in sections) s.startMeasure};
    final rows = <List<Measure>>[];
    var row = <Measure>[];

    for (final m in measures) {
      final breakForSection = sectionStarts.contains(m.number) && row.isNotEmpty && m.number != 1;
      // Row break formula: before measure m when m != 1 and (m-1) % N == 0.
      // Skipping m==1 keeps pickup measures (m=0) in the same first row as the
      // first N real measures rather than counting them against the row budget.
      final breakForRow = row.isNotEmpty &&
          m.number != 1 &&
          (m.number - 1) % measuresPerRow == 0;

      if (breakForSection || breakForRow) {
        rows.add(List.unmodifiable(row));
        row = [];
      }
      row.add(m);
    }
    if (row.isNotEmpty) rows.add(List.unmodifiable(row));

    return PieceLayout(List.unmodifiable(rows));
  }

  int get measureCount => rows.fold(0, (s, r) => s + r.length);

  /// Returns [xml] with all print/spacing elements stripped so OSMD can
  /// determine its own system breaks.
  String stripLayoutHints(String xml) {
    final doc = XmlDocument.parse(xml);

    for (final el in doc.findAllElements('print').toList()) {
      el.parent?.children.remove(el);
    }
    for (final tag in [
      'defaults', 'system-layout', 'system-distance', 'top-system-distance',
      'page-layout', 'page-margins', 'scaling', 'staff-layout', 'staff-distance',
    ]) {
      for (final el in doc.findAllElements(tag).toList()) {
        el.parent?.children.remove(el);
      }
    }

    return doc.toXmlString();
  }
}

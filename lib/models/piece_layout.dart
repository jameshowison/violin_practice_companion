import 'package:xml/xml.dart';
import 'parsed_piece.dart';
import 'section.dart';

/// Returns the number of measures per row appropriate for a given screen width.
/// Breakpoints are in logical pixels.
int measuresPerRowForWidth(double widthPx) {
  if (widthPx >= 1000) return 4;
  if (widthPx >= 700) return 3;
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
      final breakForSection = sectionStarts.contains(m.number) && row.isNotEmpty;
      final rowFull = row.length >= measuresPerRow;

      if (breakForSection || rowFull) {
        rows.add(List.unmodifiable(row));
        row = [];
      }
      row.add(m);
    }
    if (row.isNotEmpty) rows.add(List.unmodifiable(row));

    return PieceLayout(List.unmodifiable(rows));
  }

  int get measureCount => rows.fold(0, (s, r) => s + r.length);

  /// Returns [xml] with `<print new-system="yes"/>` injected at the start of
  /// every measure that begins a new row (all rows after the first).
  /// OSMD honours these elements, so the staff view matches the jianpu/fingering layout.
  String injectSystemBreaks(String xml) {
    final newSystemMeasures = <int>{
      for (int i = 1; i < rows.length; i++)
        if (rows[i].isNotEmpty) rows[i].first.number,
    };
    if (newSystemMeasures.isEmpty) return xml;

    final doc = XmlDocument.parse(xml);
    for (final measureEl in doc.findAllElements('measure')) {
      final num = int.tryParse(measureEl.getAttribute('number') ?? '');
      if (num != null && newSystemMeasures.contains(num)) {
        if (measureEl.findElements('print').isEmpty) {
          measureEl.children.insert(
            0,
            XmlElement(XmlName('print'), [
              XmlAttribute(XmlName('new-system'), 'yes'),
            ]),
          );
        }
      }
    }
    return doc.toXmlString();
  }
}

import 'package:xml/xml.dart';
import 'parsed_piece.dart';
import 'section.dart';
import 'section_run.dart';

/// Returns the number of measures per row appropriate for a given screen width.
/// Breakpoints are in logical pixels.
int measuresPerRowForWidth(double widthPx) {
  if (widthPx >= 600) return 4;
  return 2;
}

/// Pre-computed row layout for a piece. A single instance is derived once
/// (in [pieceLayoutProvider]) and shared by all notation views.
///
/// The layout is always **folded** — the score is shown as written, with repeat
/// barlines intact. The unfolded "where are we in the whole piece" view lives in
/// the minimap (see [sectionRuns]), not here.
class PieceLayout {
  final List<List<Measure>> rows;

  /// Section occurrences in display order, each spanning a contiguous range of
  /// [rows] (one run per section; a literal restatement yields a second
  /// same-label run). Empty when the piece has no section metadata. Drives the
  /// inline jianpu/fingering section headers.
  final List<SectionRun> runs;

  const PieceLayout(this.rows, {this.runs = const []});

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
      final breakForSection =
          sectionStarts.contains(m.number) && row.isNotEmpty && m.number != 1;
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

    final frozen = List<List<Measure>>.unmodifiable(rows);
    final labelByMeasure = sectionLabelByMeasure(sections, measures);
    return PieceLayout(frozen, runs: _computeRuns(frozen, labelByMeasure));
  }

  /// Groups [rows] into folded [SectionRun]s by section membership (a row
  /// belongs to the section containing its first real measure, via
  /// [labelByMeasure]). A new run begins at a label change or when a row's first
  /// measure number drops within the same label (a literal A→A restatement).
  /// Pickup-only rows attach to the current run. A post-pass assigns numbered
  /// passes per label.
  static List<SectionRun> _computeRuns(
      List<List<Measure>> rows, Map<int, String> labelByMeasure) {
    if (labelByMeasure.isEmpty || rows.isEmpty) return const [];

    int firstReal(List<Measure> row) {
      for (final m in row) {
        if (m.number >= 1) return m.number;
      }
      return row.isEmpty ? 0 : row.first.number;
    }

    int lastReal(List<Measure> row) {
      for (final m in row.reversed) {
        if (m.number >= 1) return m.number;
      }
      return row.isEmpty ? 0 : row.last.number;
    }

    // Mutable accumulation: [label, rowStart, rowEnd(excl), firstMeasure, lastMeasure].
    final acc = <List<dynamic>>[];
    String? curLabel;
    int? prevFirst;
    for (var ri = 0; ri < rows.length; ri++) {
      final row = rows[ri];
      final fm = firstReal(row);
      final lbl = labelByMeasure[fm] ?? curLabel;
      final newRun = acc.isEmpty ||
          lbl != curLabel ||
          (prevFirst != null && fm <= prevFirst && lbl == curLabel);
      if (newRun) {
        acc.add([lbl ?? '', ri, ri + 1, fm, lastReal(row)]);
        curLabel = lbl;
      } else {
        acc.last[2] = ri + 1;
        acc.last[4] = lastReal(row);
      }
      prevFirst = fm;
    }

    final counts = <String, int>{};
    for (final r in acc) {
      counts[r[0] as String] = (counts[r[0] as String] ?? 0) + 1;
    }
    final seen = <String, int>{};
    return List.unmodifiable([
      for (final r in acc)
        SectionRun(
          label: r[0] as String,
          passIndex: seen[r[0] as String] = (seen[r[0] as String] ?? -1) + 1,
          passCount: counts[r[0] as String]!,
          rowStart: r[1] as int,
          rowCount: (r[2] as int) - (r[1] as int),
          firstMeasure: r[3] as int,
          lastMeasure: r[4] as int,
        ),
    ]);
  }

  int get measureCount => rows.fold(0, (s, r) => s + r.length);

  /// Returns [xml] with all print/spacing elements stripped so the engraver can
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

/// **Unfolded** section runs in performance order — the model behind the
/// minimap. Built from [ParsedPiece.performanceOrder] + the section markers, so
/// a `|: A :|` repeat yields two consecutive A runs and a literal restatement
/// likewise yields a second A run. Each run carries its performance-order slice
/// ([SectionRun.perfStart]..[SectionRun.perfEnd]) so the minimap can light the
/// exact playing pass from a [HighlightEvent.performanceIndex].
///
/// A leading region covered by no section (genuine section-less measures) is
/// dropped; an unmarked pickup, however, attaches to the section that follows.
List<SectionRun> sectionRuns(List<Measure> measures, List<Section> sections) {
  if (sections.isEmpty || measures.isEmpty) return const [];
  final order = ParsedPiece.performanceOrder(measures);
  final labelByMeasure = sectionLabelByMeasure(sections, measures);
  final markerMeasures = {for (final s in sections) s.startMeasure};

  // [label, perfStart, perfEnd(excl), firstRealMeasure(-1 until seen), lastReal].
  final segs = <List<dynamic>>[];
  var runHasReal = false;
  for (var oi = 0; oi < order.length; oi++) {
    final m = measures[order[oi]];
    final lbl = labelByMeasure[m.number];
    final atSectionStart = markerMeasures.contains(m.number);
    final begin = segs.isEmpty || (atSectionStart && runHasReal);
    if (begin) {
      segs.add([lbl ?? '', oi, oi + 1, m.number >= 1 ? m.number : -1, m.number]);
      runHasReal = m.number >= 1;
    } else {
      segs.last[2] = oi + 1;
      // An unmarked leading pickup adopts the following section's label.
      if (lbl != null && (segs.last[0] as String).isEmpty) segs.last[0] = lbl;
      if (m.number >= 1) {
        if ((segs.last[3] as int) < 0) segs.last[3] = m.number;
        segs.last[4] = m.number;
        runHasReal = true;
      }
    }
  }

  final kept = segs.where((s) => (s[0] as String).isNotEmpty).toList();
  final counts = <String, int>{};
  for (final s in kept) {
    counts[s[0] as String] = (counts[s[0] as String] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return List.unmodifiable([
    for (final s in kept)
      SectionRun(
        label: s[0] as String,
        passIndex: seen[s[0] as String] = (seen[s[0] as String] ?? -1) + 1,
        passCount: counts[s[0] as String]!,
        firstMeasure: (s[3] as int) < 0 ? (s[4] as int) : s[3] as int,
        lastMeasure: s[4] as int,
        perfStart: s[1] as int,
        perfEnd: s[2] as int,
      ),
  ]);
}

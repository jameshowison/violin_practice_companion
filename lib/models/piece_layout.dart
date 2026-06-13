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
class PieceLayout {
  final List<List<Measure>> rows;

  /// Section occurrences in display order, each spanning a contiguous range of
  /// [rows]. Empty when the piece has no section metadata. Drives the inline
  /// section headers, the minimap, and section navigation.
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

    // Folded layout carries no section runs: the minimap, margin bars, inline
    // headers and section coloring are all ABAA-only (see [computeSectioned]).
    return PieceLayout(List<List<Measure>>.unmodifiable(rows));
  }

  /// Section-organized ("ABAA") layout. Repeats are unfolded into performance
  /// order (so a `|: A :|` span yields two `A` runs), every section begins a new
  /// row, and a long section wraps at [measuresPerRow] into continuation rows
  /// (the staff equivalent of multiple systems within one section).
  ///
  /// A repeated measure appears more than once here and shares its [Measure]
  /// (and therefore its number) across copies — that is intentional: selection
  /// and the playback cursor key off the measure number, so every copy of a
  /// recurring section highlights together, showing where it happens again.
  factory PieceLayout.computeSectioned(
    List<Measure> measures,
    List<Section> sections, {
    int measuresPerRow = 4,
  }) {
    final order = ParsedPiece.performanceOrder(measures);
    final runStarts = _sectionRunStarts(measures, sections);
    final rows = <List<Measure>>[];
    var row = <Measure>[];
    var countInRun = 0;

    for (var oi = 0; oi < order.length; oi++) {
      // Repeats are unfolded into separate copies here, so the `|:`/`:|`
      // barline glyphs no longer apply — clear them on the emitted copies so
      // the jianpu/fingering views don't draw stale repeat brackets. (The
      // staff does the equivalent in SectionUnfoldXml.)
      final src = measures[order[oi]];
      final m = (src.repeatStart || src.repeatEnd)
          ? src.copyWithNotes(src.notes, repeatStart: false, repeatEnd: false)
          : src;
      if (runStarts.contains(oi)) {
        if (row.isNotEmpty) rows.add(List.unmodifiable(row));
        row = [];
        countInRun = 0;
      } else if (row.isNotEmpty &&
          countInRun > 0 &&
          countInRun % measuresPerRow == 0) {
        rows.add(List.unmodifiable(row));
        row = [];
      }
      row.add(m);
      countInRun++;
    }
    if (row.isNotEmpty) rows.add(List.unmodifiable(row));

    final frozen = List<List<Measure>>.unmodifiable(rows);
    return PieceLayout(frozen, runs: _computeRuns(frozen, sections));
  }

  /// Groups [rows] into [SectionRun]s by section membership (a row belongs to
  /// the section containing its first real measure). A new run begins at a label
  /// change or when a row's first measure number drops within the same label
  /// (the A→A repeat wrap in ABAA mode). Pickup-only rows attach to the current
  /// run. A post-pass assigns numbered passes per label.
  static List<SectionRun> _computeRuns(
      List<List<Measure>> rows, List<Section> sections) {
    if (sections.isEmpty || rows.isEmpty) return const [];

    String? labelFor(int number) {
      for (final s in sections) {
        if (number >= s.startMeasure && number <= s.endMeasure) return s.label;
      }
      return null;
    }

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
      final lbl = labelFor(fm) ?? curLabel;
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

  /// Positions in [ParsedPiece.performanceOrder] that begin a new section
  /// "run" (a new system in section-organized mode). A run begins at any
  /// section-start measure — including the wrap-around when a repeat returns to
  /// a section's start — except while the current run holds only a pickup
  /// (measure 0), so a pickup stays attached to the section that follows it.
  /// Shared by [computeSectioned] and the staff XML unfold so both break
  /// identically.
  static Set<int> sectionRunStarts(
          List<Measure> measures, List<Section> sections) =>
      _sectionRunStarts(measures, sections);

  static Set<int> _sectionRunStarts(
      List<Measure> measures, List<Section> sections) {
    final order = ParsedPiece.performanceOrder(measures);
    final sectionStarts = {for (final s in sections) s.startMeasure};
    final starts = <int>{};
    var runHasRealMeasure = false;
    for (var oi = 0; oi < order.length; oi++) {
      final m = measures[order[oi]];
      if (oi > 0 && sectionStarts.contains(m.number) && runHasRealMeasure) {
        starts.add(oi);
        runHasRealMeasure = false;
      }
      if (m.number >= 1) runHasRealMeasure = true;
    }
    return starts;
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

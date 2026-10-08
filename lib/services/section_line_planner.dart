import 'dart:math' as math;

/// Section-aware line breaking: every section occupies whole lines — one if it
/// fits, else the fewest that do — with its bars spread so the lines are as
/// even in WIDTH as possible.
///
/// Pure Dart, no Verovio: it works on numbers the staff view measures.
///
/// * [widths] — each engraved measure's natural width (MEI units), in engraved
///   order. A split bar's two slices are two entries.
/// * [segmentStarts] — engraved positions where a line MUST start: 0 and every
///   section start (the `<print new-system>`s `insertSystemBreaks` put there).
/// * [maxLineUnits] — the widest a line may be and still engrave at the
///   smallest acceptable staff size.
///
/// * [lines] — when set, every segment takes exactly this many lines (or one
///   per bar, if it has fewer bars), whatever the width: the user's own
///   lines-per-section zoom. [maxLineUnits] is then ignored.
///
/// Returns the positions of the extra breaks planned inside segments, the
/// width of the widest resulting line, which sets the scale, and the most
/// lines any segment took.
///
/// Why by width rather than bar count: a section often carries a lead-in half
/// bar at its start and a half bar at its end, and a bar of running eighths
/// with words under it can be twice as wide as a held note. Splitting 8 bars
/// "4 + 4" put the lead-in AND four full bars on the first line — the widest
/// line, which sets the size for every line. Balancing by width moves a bar to
/// the second line instead (measured on Along the Road to Gundagai in
/// portrait, with lyrics: staff scale 26 → 31.5).
///
/// Ties go to the plan whose EARLIER lines are shorter, so a section's first
/// line — the one that opens with the lead-in — is the lighter one.
({Set<int> breaks, double widestUnits, int maxLines}) planSectionLines({
  required List<double> widths,
  required List<int> segmentStarts,
  required double maxLineUnits,
  int? lines,
}) {
  final starts = {...segmentStarts, 0}.where((s) => s < widths.length).toList()
    ..sort();
  final breaks = <int>{};
  var widest = 0.0;
  var maxLines = 0;
  for (var g = 0; g < starts.length; g++) {
    final from = starts[g];
    final to = g + 1 < starts.length ? starts[g + 1] : widths.length;
    final seg = widths.sublist(from, to);
    final plan = lines == null
        ? _fewestLines(seg, maxLineUnits)
        : balancedLines(seg, lines);
    for (final b in plan.breaks) {
      breaks.add(from + b);
    }
    widest = math.max(widest, plan.widest);
    maxLines = math.max(maxLines, plan.breaks.length + 1);
  }
  return (breaks: breaks, widestUnits: widest, maxLines: maxLines);
}

/// The fewest lines [seg] fits in at ≤ [maxLine] each (or one bar a line when
/// nothing fits), balanced by width.
({List<int> breaks, double widest}) _fewestLines(
    List<double> seg, double maxLine) {
  for (var k = 1; k <= seg.length; k++) {
    final plan = balancedLines(seg, k);
    if (plan.widest <= maxLine || k == seg.length) return plan;
  }
  return (breaks: const [], widest: 0);
}

/// [seg] cut into exactly [k] contiguous lines minimising the widest; ties
/// broken toward shorter earlier lines. Returns the cut positions (relative to
/// [seg], each the first bar of a new line) and the widest line's width.
///
/// Exhaustive over cut positions with memoisation — a section is a few dozen
/// bars at most and k is small, so this is instant and needs no cleverness.
({List<int> breaks, double widest}) balancedLines(List<double> seg, int k) {
  final n = seg.length;
  if (n == 0) return (breaks: const [], widest: 0);
  k = k.clamp(1, n);
  final prefix = [0.0];
  for (final w in seg) {
    prefix.add(prefix.last + w);
  }
  double sum(int a, int b) => prefix[b] - prefix[a];

  // best[(i, j)] = optimal way to lay bars i.. onto j lines: (widest, the
  // sequence of line widths for the tie-break, the cuts).
  final memo = <int, ({double widest, List<double> lines, List<int> cuts})>{};
  ({double widest, List<double> lines, List<int> cuts}) solve(int i, int j) {
    final key = i * (k + 1) + j;
    final hit = memo[key];
    if (hit != null) return hit;
    ({double widest, List<double> lines, List<int> cuts}) out;
    if (j == 1) {
      final w = sum(i, n);
      out = (widest: w, lines: [w], cuts: const []);
    } else {
      ({double widest, List<double> lines, List<int> cuts})? best;
      // The first line takes bars i..e-1, leaving at least one bar per line.
      for (var e = i + 1; e <= n - (j - 1); e++) {
        final first = sum(i, e);
        final rest = solve(e, j - 1);
        final cand = (
          widest: math.max(first, rest.widest),
          lines: [first, ...rest.lines],
          cuts: [e, ...rest.cuts],
        );
        if (best == null || _better(cand, best)) best = cand;
      }
      out = best!;
    }
    memo[key] = out;
    return out;
  }

  final r = solve(0, k);
  return (breaks: r.cuts, widest: r.widest);
}

const _eps = 1e-6;

bool _better(({double widest, List<double> lines, List<int> cuts}) a,
    ({double widest, List<double> lines, List<int> cuts}) b) {
  if ((a.widest - b.widest).abs() > _eps) return a.widest < b.widest;
  for (var i = 0; i < a.lines.length && i < b.lines.length; i++) {
    if ((a.lines[i] - b.lines[i]).abs() > _eps) return a.lines[i] < b.lines[i];
  }
  return false;
}

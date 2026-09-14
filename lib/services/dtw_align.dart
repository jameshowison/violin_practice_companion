import 'dart:typed_data';

/// Result of aligning two feature sequences with dynamic time warping.
class DtwResult {
  /// `path[k] = (referenceFrameIndex, targetFrameIndex)`, non-decreasing in
  /// both components. Empty if either input sequence was empty. With the
  /// default closed boundaries, runs from `(0, 0)` to the last frame of each
  /// sequence. With `openBegin`/`openEnd` (see [DtwAligner.align]), the path
  /// still covers every reference frame but may start and/or end at a target
  /// frame other than `0`/`m-1` — the excluded leading/trailing target frames
  /// are the discovered unmatched intro/outro.
  final List<(int, int)> path;

  /// Mean per-step cost along the optimal path — cosine distance, so 0 is a
  /// perfect frame-for-frame match and 2 is the worst possible. There's no
  /// built-in pass/fail threshold: DTW always returns *some* alignment, so
  /// this is only a rough smell test (e.g. for logging), not a guarantee.
  final double averageCost;

  const DtwResult(this.path, this.averageCost);
}

/// Classic dynamic-time-warping alignment between two sequences of feature
/// vectors (e.g. chroma frames), using cosine distance and a Sakoe-Chiba
/// band around the diagonal — this both bounds the search and discourages
/// alignments that don't correspond to any plausible tempo relationship
/// between the two sequences.
///
/// Cost is stored as a dense `(n+1) x (m+1)` matrix. That's O(n·m) memory,
/// fine for pieces up to a few minutes (a few thousand frames each way, a
/// few tens of MB) — the intended use case, run once per piece/track and
/// cached. A banded sparse representation would be the next step if this
/// ever needs to run on much longer material.
///
/// Optional `openBegin`/`openEnd` alignment (see [align]) bypasses the band
/// entirely and runs an unbounded search instead, since the band's
/// diagonal-centering assumption presumes synchronized start/end points.
class DtwAligner {
  /// Half-width of the band, as a fraction of the longer sequence's length
  /// (e.g. 0.25 allows the warp to wander up to 25% off the diagonal).
  final double bandFraction;

  /// Cost charged per skipped leading/trailing [target] frame in open-begin
  /// /open-end mode (see [align]) — small next to a genuine mismatch's cost
  /// (cosine distance up to 2), but enough to break the near-ties a long
  /// sustained, near-uniform stretch of audio produces (every frame inside a
  /// held note looks almost identical, so skipping a few of them can look
  /// free to floating-point precision without this). Without it, open
  /// boundaries can shave real content off a boundary for a change in cost
  /// too small to be a genuine improvement, rather than only skipping actual
  /// unmatched intro/outro content.
  static const double _skipPenaltyPerFrame = 1e-3;

  const DtwAligner({this.bandFraction = 0.25});

  /// [openBegin]/[openEnd] allow the path to skip leading and/or trailing
  /// [target] frames that have no counterpart in [reference] — e.g. a
  /// recorded intro/outro the score doesn't have — at a small per-frame cost
  /// (see [_skipPenaltyPerFrame]) rather than forcing them into a false
  /// match. Every [reference] frame is still consumed; only the [target]
  /// boundaries relax. Both default to `false` (today's corner-to-corner
  /// behavior).
  DtwResult align(
    List<Float64List> reference,
    List<Float64List> target, {
    bool openBegin = false,
    bool openEnd = false,
  }) {
    final n = reference.length;
    final m = target.length;
    if (n == 0 || m == 0) return const DtwResult([], 0);

    if (openBegin || openEnd) {
      return _alignWithBand(reference, target, 1.0,
              openBegin: openBegin, openEnd: openEnd) ??
          const DtwResult([], double.infinity); // unreachable at bandFraction 1.0
    }

    var result = _alignWithBand(reference, target, bandFraction);
    // The configured band excluded every path to (n, m) — fall back to an
    // effectively unbounded band rather than fail outright.
    result ??= _alignWithBand(reference, target, 1.0);
    if (result == null) {
      // Should be unreachable with bandFraction 1.0, but don't let a bug
      // here surface as a crash — report an empty, maximally-costly result.
      return const DtwResult([], double.infinity);
    }
    return result;
  }

  DtwResult? _alignWithBand(
    List<Float64List> reference,
    List<Float64List> target,
    double bandFraction, {
    bool openBegin = false,
    bool openEnd = false,
  }) {
    final n = reference.length;
    final m = target.length;
    final band =
        (bandFraction * (n > m ? n : m)).ceil().clamp(1, n + m).toInt();

    final cost = List.generate(n + 1, (_) => Float32List(m + 1));
    for (final row in cost) {
      row.fillRange(0, row.length, double.infinity);
    }
    // Row 0 = "0 reference frames consumed." Closed mode allows only (0, 0)
    // for free; open-begin lets reference frame 0 pair with any target frame
    // j, charging only the skip penalty for the j frames skipped ahead of it
    // (a flat 0 for every j, rather than this ramp, is tempting but wrong —
    // see [_skipPenaltyPerFrame].)
    if (openBegin) {
      for (var j = 0; j <= m; j++) {
        cost[0][j] = _skipPenaltyPerFrame * j;
      }
    } else {
      cost[0][0] = 0;
    }

    for (var i = 1; i <= n; i++) {
      final jCenter = (i * m / n).round();
      final jLo = (jCenter - band).clamp(1, m);
      final jHi = (jCenter + band).clamp(1, m);
      final refFrame = reference[i - 1];
      final costRow = cost[i];
      final prevRow = cost[i - 1];
      for (var j = jLo; j <= jHi; j++) {
        final d = _cosineDistance(refFrame, target[j - 1]);
        final best = _min3(prevRow[j], costRow[j - 1], prevRow[j - 1]);
        costRow[j] = d + best;
      }
    }

    // Closed mode must land on (n, m); open-end instead takes whichever
    // target frame gives the cheapest fully-referenced path once the skip
    // penalty for the (m - j) frames left unmatched after it is added back
    // in — leaving them unmatched only when that's a genuine improvement,
    // not merely a shorter sum (see [_skipPenaltyPerFrame]).
    var jEnd = m;
    if (openEnd) {
      var bestAdjusted = double.infinity;
      for (var j = 1; j <= m; j++) {
        if (!cost[n][j].isFinite) continue;
        final adjusted = cost[n][j] + _skipPenaltyPerFrame * (m - j);
        if (adjusted < bestAdjusted) {
          bestAdjusted = adjusted;
          jEnd = j;
        }
      }
    }
    if (!cost[n][jEnd].isFinite) return null;

    final path = <(int, int)>[];
    var i = n, j = jEnd;
    // Closed-begin stops only once both (0, 0) are reached; open-begin stops
    // as soon as every reference frame is consumed, regardless of j — the
    // frames short of wherever it stops are the discovered unmatched intro.
    while (i > 0 && (openBegin || j > 0)) {
      path.add((i - 1, j - 1));
      // Only the "up" move (decrementing i) is legal once j hits 0 — guard
      // diag/left so the open-begin loop can't index target[-1].
      final diag = j > 0 ? cost[i - 1][j - 1] : double.infinity;
      final up = cost[i - 1][j];
      final left = j > 0 ? cost[i][j - 1] : double.infinity;
      if (diag <= up && diag <= left) {
        i--;
        j--;
      } else if (up <= left) {
        i--;
      } else {
        j--;
      }
    }
    final orderedPath = path.reversed.toList(growable: false);
    // cost[n][jEnd] includes the open-begin skip penalty charged once, at the
    // base case, for however many target frames were skipped ahead of
    // orderedPath.first — back it out so averageCost reports genuine match
    // quality rather than this tie-breaking regularizer (open-end's penalty
    // never entered cost[n][jEnd] to begin with; it's only used above to
    // choose jEnd, so it needs no equivalent correction here).
    final jStart = orderedPath.isEmpty ? 0 : orderedPath.first.$2;
    final skipPenaltyPaid = openBegin ? _skipPenaltyPerFrame * jStart : 0.0;
    final matchCost = cost[n][jEnd] - skipPenaltyPaid;
    return DtwResult(orderedPath, matchCost / orderedPath.length);
  }

  static double _cosineDistance(Float64List a, Float64List b) {
    var dot = 0.0;
    for (var k = 0; k < a.length; k++) {
      dot += a[k] * b[k];
    }
    return 1.0 - dot;
  }

  static double _min3(double a, double b, double c) {
    final ab = a < b ? a : b;
    return c < ab ? c : ab;
  }
}

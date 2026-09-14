import 'dart:typed_data';

/// Result of aligning two feature sequences with dynamic time warping.
class DtwResult {
  /// `path[k] = (referenceFrameIndex, targetFrameIndex)`, non-decreasing in
  /// both components, running from `(0, 0)` to the last frame of each
  /// sequence. Empty if either input sequence was empty.
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
class DtwAligner {
  /// Half-width of the band, as a fraction of the longer sequence's length
  /// (e.g. 0.25 allows the warp to wander up to 25% off the diagonal).
  final double bandFraction;

  const DtwAligner({this.bandFraction = 0.25});

  DtwResult align(List<Float64List> reference, List<Float64List> target) {
    final n = reference.length;
    final m = target.length;
    if (n == 0 || m == 0) return const DtwResult([], 0);

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
    double bandFraction,
  ) {
    final n = reference.length;
    final m = target.length;
    final band =
        (bandFraction * (n > m ? n : m)).ceil().clamp(1, n + m).toInt();

    final cost = List.generate(n + 1, (_) => Float32List(m + 1));
    for (final row in cost) {
      row.fillRange(0, row.length, double.infinity);
    }
    cost[0][0] = 0;

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

    if (!cost[n][m].isFinite) return null;

    final path = <(int, int)>[];
    var i = n, j = m;
    while (i > 0 && j > 0) {
      path.add((i - 1, j - 1));
      final diag = cost[i - 1][j - 1];
      final up = cost[i - 1][j];
      final left = cost[i][j - 1];
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
    return DtwResult(orderedPath, cost[n][m] / orderedPath.length);
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

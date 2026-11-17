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

  /// Mean per-step cost along the optimal path — cosine distance (plus the
  /// attack term, when [DtwAligner.align] was given onsets), so 0 is a
  /// perfect frame-for-frame match and 2 is the worst possible cosine. There's no
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
  /// /open-end mode (see [align]).
  ///
  /// What this really buys is *coverage*. Every reference frame pays its own
  /// cosine distance wherever it lands, so skipping saves nothing directly —
  /// but a free skip lets the path choose any sub-window of the target and
  /// cram the whole reference into it with vertical moves, picking whichever
  /// frames happen to match best and ignoring whether the result is a
  /// plausible passage of time. Charging per declined target frame is what
  /// makes a narrow window expensive, and so makes a wide, roughly diagonal
  /// path win. Set the charge near the typical per-frame match cost and a
  /// frame is explained exactly when it plausibly matches; set it far below
  /// and the window collapses.
  ///
  /// Chroma vectors here are non-negative and unit-length, so their cosine
  /// distance is bounded in `[0, 1]`, not the `[0, 2]` the general case
  /// allows, and a whole-alignment mean of about 0.4 is normal on a real
  /// recording.
  ///
  /// It used to be 1e-3, chosen only to break the near-ties a long sustained
  /// stretch of near-identical frames produces. That is orders of magnitude
  /// below the cost of matching anything, which made discarding the rest of
  /// the recording almost free. Paired with the band-limited chroma front end
  /// (see [AudioChromaExtractor]), 1e-3 closed the Galopede teacher demo's
  /// boundaries onto a 14s window and put its first anchor 29s after the
  /// first note.
  ///
  /// This default is the centre of the window that satisfies both real
  /// recordings, each of which pins one side of it:
  ///
  /// - **Below ~0.13**, the Galopede demo's window collapses. Its mean anchor
  ///   error against a by-ear ground truth is 18.66s at 1e-3, 3.97s at 0.10,
  ///   and 0.60s from 0.13 up.
  /// - **Above ~0.23**, Lightly Row's first anchor is dragged back into its
  ///   intro. That recording opens by restating the tune's first phrase
  ///   before the performance proper, so the intro genuinely resembles the
  ///   score's opening and stops being worth skipping once declining it gets
  ///   expensive: anchor 0 jumps 6.57s -> 3.11s and the first segment then
  ///   paces at 2.4x the rest of the piece, where a correct anchor 0 paces at
  ///   1.04x.
  ///
  /// That second constraint is the one to keep in mind when retuning: a
  /// recording whose intro or outro quotes the tune is the hard case, and
  /// raising this value is what breaks it. See
  /// docs/audio-sync-dtw-interior-gaps.md.
  final double skipPenaltyPerFrame;

  /// Extra cost of a non-diagonal step: holding a reference frame over
  /// another target frame, or a target frame over another reference frame.
  ///
  /// Without it, where the audio gives no evidence the path may warp freely,
  /// and a score's rests give none: a rest's reference frame is all zero, so
  /// it costs 1 against every target frame and is the same price wherever it
  /// lands. On a solo teacher video of a 2/4 piece (four bars of rest, then
  /// bars of repeated G–D eighths) the rests soaked up whatever audio matched
  /// worst, the G–D bars after them slipped a whole bar late, and two bars
  /// stretched to 5.4 and 6.0 s against a steady 1.41. With this charge the
  /// path keeps the local tempo through stretches it can't see, and those
  /// bars land within 0.1 s of their onsets.
  ///
  /// It is small next to a typical match cost (~0.3), so a real tempo change
  /// still pays for itself; Galopede, Gundagai, Lightly Row and Salt Creek
  /// align as before.
  final double stepPenalty;

  /// Weight of the attack term added to each frame pair's cost: this times
  /// the difference between the score's attack (1 where a note starts) and
  /// the recording's (see [ChromaSequence.onsets]), each spread a frame
  /// either side. Used only when [align] is given both.
  ///
  /// Chroma alone can't see a note played again: thirteen bars of repeated
  /// sixteenth-note Ds look like one long D, so their barlines are invisible
  /// and the bars drift at whatever tempo the path happens to keep. Attacks
  /// make each stroke a landmark. On that recording (Trepak's "D to the end")
  /// the closing bars went from ~1 s late to within 0.1 s of their onsets,
  /// and the anchors on Gundagai's real fiddle recording within 100 ms of an
  /// onset rose from 27 to 29 of 33. 0.3 is the middle of the range that
  /// helped (on a 22 kHz conversion, at a spread of one frame): 0.15 left
  /// half the drift, 0.6 started to disturb bars 2-11. The caller passes a
  /// spread fixed in seconds (`onsetSpreadFrames`), so the weight means the
  /// same at any sample rate.
  final double onsetWeight;

  /// The most reference frames one target frame may take up: how much faster
  /// than the reference the recording may locally run. Null is unlimited.
  ///
  /// A performer can stop for as long as they like (a page turn, talking in
  /// a rest), so the target side stays unlimited. But nobody plays a passage
  /// at three times the tempo of the rest of the piece, and the reference's
  /// tempo is the performer's own by the second pass. Unlimited, the path
  /// could use vertical moves to stack a run of bars onto a moment of audio,
  /// and an open boundary made that a real option: on a teacher video whose
  /// first twelve bars are the same rest-and-A, it treated eight bars' worth
  /// of played As as intro and crushed bars 1-7 into about a second, with
  /// five of them taking no time at all. Bar 1 came out at 24.9 s against a
  /// true 12.5 s. The step penalty can't price that out without also
  /// taxing real tempo changes, and charging per crushed note start is
  /// dodged by stepping forward one frame at each note.
  ///
  /// 2 is a step pattern: a vertical move is only ever half of a two-frame
  /// step that ends in a diagonal, so it needs no extra memory. It put that
  /// video's bars 1-12 on their notes; 3 still let them be crushed to about
  /// twice the tempo. Galopede, Gundagai, Lightly Row, Salt Creek and the
  /// synthetic intro/outro sweep align as before.
  final int? maxReferenceStride;

  const DtwAligner({
    this.bandFraction = 0.25,
    this.skipPenaltyPerFrame = 0.18,
    this.stepPenalty = 0.05,
    this.onsetWeight = 0.3,
    this.maxReferenceStride = 2,
  });

  /// [openBegin]/[openEnd] allow the path to skip leading and/or trailing
  /// [target] frames that have no counterpart in [reference] — e.g. a
  /// recorded intro/outro the score doesn't have — at a small per-frame cost
  /// (see [skipPenaltyPerFrame]) rather than forcing them into a false
  /// match. Every [reference] frame is still consumed; only the [target]
  /// boundaries relax. Both default to `false` (today's corner-to-corner
  /// behavior).
  DtwResult align(
    List<Float64List> reference,
    List<Float64List> target, {
    bool openBegin = false,
    bool openEnd = false,
    Float64List? referenceOnsets,
    Float64List? targetOnsets,
    int onsetSpreadFrames = 1,
  }) {
    final n = reference.length;
    final m = target.length;
    if (n == 0 || m == 0) return const DtwResult([], 0);

    final useOnsets = onsetWeight > 0 &&
        referenceOnsets != null &&
        targetOnsets != null &&
        referenceOnsets.length == n &&
        targetOnsets.length == m;
    final ro = useOnsets ? _smear(referenceOnsets, onsetSpreadFrames) : null;
    final to = useOnsets ? _smear(targetOnsets, onsetSpreadFrames) : null;
    double distance(int i, int j) {
      final d = _cosineDistance(reference[i], target[j]);
      if (ro == null) return d;
      return d + onsetWeight * (ro[i] - to![j]).abs();
    }

    if (openBegin || openEnd) {
      return _alignWithBand(reference, target, 1.0, distance,
              openBegin: openBegin, openEnd: openEnd) ??
          const DtwResult([], double.infinity); // unreachable at bandFraction 1.0
    }

    var result = _alignWithBand(reference, target, bandFraction, distance);
    // The configured band excluded every path to (n, m) — fall back to an
    // effectively unbounded band rather than fail outright.
    result ??= _alignWithBand(reference, target, 1.0, distance);
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
    double Function(int, int) distance, {
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
    // see [skipPenaltyPerFrame].)
    if (openBegin) {
      for (var j = 0; j <= m; j++) {
        cost[0][j] = skipPenaltyPerFrame * j;
      }
    } else {
      cost[0][0] = 0;
    }

    final stride = maxReferenceStride;
    // With a stride limit, a vertical run is only taken as one step of up to
    // [stride] reference frames ending in a diagonal, so these hold the last
    // few rows' distances for the cells such a step passes through.
    final dRows = stride == null
        ? const <Float64List>[]
        : List.generate(stride, (_) => Float64List(m + 1));
    for (var i = 1; i <= n; i++) {
      final jCenter = (i * m / n).round();
      final jLo = (jCenter - band).clamp(1, m);
      final jHi = (jCenter + band).clamp(1, m);
      final costRow = cost[i];
      final prevRow = cost[i - 1];
      if (stride == null) {
        for (var j = jLo; j <= jHi; j++) {
          final d = distance(i - 1, j - 1);
          final best = _min3(prevRow[j] + stepPenalty,
              costRow[j - 1] + stepPenalty, prevRow[j - 1]);
          costRow[j] = d + best;
        }
        continue;
      }
      final dRow = dRows[i % stride]..fillRange(0, m + 1, double.infinity);
      for (var j = jLo; j <= jHi; j++) {
        final d = distance(i - 1, j - 1);
        dRow[j] = d;
        var best = prevRow[j - 1];
        final left = costRow[j - 1] + stepPenalty;
        if (left < best) best = left;
        var through = 0.0;
        for (var k = 2; k <= stride && i - k >= 0; k++) {
          through += dRows[(i - k + 1) % stride][j] + stepPenalty;
          if (!through.isFinite) break;
          final c = cost[i - k][j - 1] + through;
          if (c < best) best = c;
        }
        costRow[j] = d + best;
      }
    }

    // Closed mode must land on (n, m); open-end instead takes whichever
    // target frame gives the cheapest fully-referenced path once the skip
    // penalty for the (m - j) frames left unmatched after it is added back
    // in — leaving them unmatched only when that's a genuine improvement,
    // not merely a shorter sum (see [skipPenaltyPerFrame]).
    var jEnd = m;
    if (openEnd) {
      var bestAdjusted = double.infinity;
      for (var j = 1; j <= m; j++) {
        if (!cost[n][j].isFinite) continue;
        final adjusted = cost[n][j] + skipPenaltyPerFrame * (m - j);
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
      if (stride != null) {
        if (j == 0) break; // unreachable: column 0 is finite only at (0, 0)
        var best = cost[i - 1][j - 1];
        var bestK = 1; // 1 = diagonal, 0 = horizontal, k >= 2 = a stride
        final left = cost[i][j - 1] + stepPenalty;
        var through = 0.0;
        for (var k = 2; k <= stride && i - k >= 0; k++) {
          through += distance(i - k, j - 1) + stepPenalty;
          final c = cost[i - k][j - 1] + through;
          if (c < best) {
            best = c;
            bestK = k;
          }
        }
        if (left < best) bestK = 0;
        if (bestK == 0) {
          j--;
        } else {
          for (var t = 1; t < bestK; t++) {
            path.add((i - t - 1, j - 1));
          }
          i -= bestK;
          j--;
        }
        continue;
      }
      // Only the "up" move (decrementing i) is legal once j hits 0 — guard
      // diag/left so the open-begin loop can't index target[-1].
      final diag = j > 0 ? cost[i - 1][j - 1] : double.infinity;
      final up = cost[i - 1][j] + stepPenalty;
      final left = j > 0 ? cost[i][j - 1] + stepPenalty : double.infinity;
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
    if (orderedPath.isEmpty) return const DtwResult([], 0);
    // Re-sum the real distances along the chosen path rather than reading
    // cost[n][jEnd] and backing the skip penalty out of it. That subtraction
    // cancelled two Float32-rounded quantities, so the residue scaled with
    // [skipPenaltyPerFrame] — at 0.18 a genuinely perfect match reported an
    // averageCost of ~7e-9 instead of 0. This also makes averageCost exactly
    // what its doc comment claims: the mean per-step distance (cosine, plus
    // any attack term), with no contribution from the skip regularizer at
    // either boundary.
    var matchCost = 0.0;
    for (final (r, t) in orderedPath) {
      matchCost += distance(r, t);
    }
    return DtwResult(orderedPath, matchCost / orderedPath.length);
  }

  static double _cosineDistance(Float64List a, Float64List b) {
    var dot = 0.0;
    for (var k = 0; k < a.length; k++) {
      dot += a[k] * b[k];
    }
    return 1.0 - dot;
  }

  /// [v] spread [radius] frames either side, tapering linearly, so an attack
  /// a frame or two off still mostly matches.
  static Float64List _smear(Float64List v, int radius) {
    final out = Float64List(v.length);
    for (var i = 0; i < v.length; i++) {
      var x = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final at = i + k;
        if (at < 0 || at >= v.length) continue;
        final y = v[at] * (1 - k.abs() / (radius + 1));
        if (y > x) x = y;
      }
      out[i] = x;
    }
    return out;
  }

  static double _min3(double a, double b, double c) {
    final ab = a < b ? a : b;
    return c < ab ? c : ab;
  }
}

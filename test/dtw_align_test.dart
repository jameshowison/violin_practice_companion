import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/dtw_align.dart';

Float64List _vec(List<double> values) => Float64List.fromList(values);

void main() {
  group('DtwAligner', () {
    test('empty input yields an empty, zero-cost result', () {
      final result = const DtwAligner().align([], []);
      expect(result.path, isEmpty);
      expect(result.averageCost, 0);
    });

    test('identical sequences align on the diagonal with zero cost', () {
      final seq = [
        _vec([1, 0, 0]),
        _vec([0, 1, 0]),
        _vec([0, 0, 1]),
        _vec([1, 0, 0]),
      ];
      final result = const DtwAligner().align(seq, seq);
      expect(result.path, [(0, 0), (1, 1), (2, 2), (3, 3)]);
      expect(result.averageCost, closeTo(0, 1e-9));
    });

    test('a slower target (each reference frame held twice) still aligns '
        'every reference frame monotonically', () {
      final reference = [
        _vec([1, 0]),
        _vec([0, 1]),
        _vec([1, 0]),
      ];
      // Target plays the same 3-frame pattern at half tempo (each frame
      // held for two target frames).
      final target = [
        _vec([1, 0]),
        _vec([1, 0]),
        _vec([0, 1]),
        _vec([0, 1]),
        _vec([1, 0]),
        _vec([1, 0]),
      ];
      final result = const DtwAligner().align(reference, target);
      expect(result.averageCost, closeTo(0, 1e-9));
      // Every reference frame must appear, in non-decreasing target order.
      final refIndices = result.path.map((p) => p.$1).toSet();
      expect(refIndices, {0, 1, 2});
      for (var k = 1; k < result.path.length; k++) {
        expect(result.path[k].$2, greaterThanOrEqualTo(result.path[k - 1].$2));
        expect(result.path[k].$1, greaterThanOrEqualTo(result.path[k - 1].$1));
      }
      // Path must start at the very first frame pair and end at the last.
      expect(result.path.first, (0, 0));
      expect(result.path.last, (2, 5));
    });

    test('a narrow band that excludes the true path still finds one '
        '(falls back to an unbounded search)', () {
      // Reference and target are totally unrelated in length/content, so a
      // tiny band would exclude (n, m) entirely.
      final reference = [_vec([1, 0]), _vec([0, 1])];
      final target = List.generate(20, (i) => _vec([i.isEven ? 1.0 : 0.0, i.isEven ? 0.0 : 1.0]));
      final result = const DtwAligner(bandFraction: 0.01).align(reference, target);
      expect(result.path, isNotEmpty);
      expect(result.path.first, (0, 0));
      expect(result.path.last, (1, 19));
    });

    test('dissimilar sequences report a higher average cost than similar ones', () {
      final a = [_vec([1, 0]), _vec([1, 0]), _vec([1, 0])];
      final similar = [_vec([1, 0]), _vec([1, 0]), _vec([1, 0])];
      final dissimilar = [_vec([0, 1]), _vec([0, 1]), _vec([0, 1])];
      final goodResult = const DtwAligner().align(a, similar);
      final badResult = const DtwAligner().align(a, dissimilar);
      expect(goodResult.averageCost, lessThan(badResult.averageCost));
    });

    group('open boundaries', () {
      // Orthogonal to every `real` frame below, so cosine distance against
      // any of them is exactly 1.0 — an unambiguous stand-in for unrelated
      // "intro"/"outro" audio content the score has no counterpart for.
      final introFrame = _vec([0, 0, 1]);
      final real = [_vec([1, 0, 0]), _vec([0, 1, 0]), _vec([1, 0, 0])];

      test('openBegin skips a leading unmatched run and finds where the '
          'real content starts', () {
        final target = [introFrame, introFrame, introFrame, ...real];
        final result = const DtwAligner()
            .align(real, target, openBegin: true, openEnd: false);
        expect(result.path.first, (0, 3));
        expect(result.path.last, (2, 5));
        expect(result.averageCost, closeTo(0, 1e-9));
      });

      test('openEnd skips a trailing unmatched run and finds where the '
          'real content ends', () {
        final target = [...real, introFrame, introFrame, introFrame];
        final result = const DtwAligner()
            .align(real, target, openBegin: false, openEnd: true);
        expect(result.path.first, (0, 0));
        expect(result.path.last, (2, 2));
        expect(result.averageCost, closeTo(0, 1e-9));
      });

      test('openBegin and openEnd together skip both a leading and '
          'trailing unmatched run', () {
        final target = [
          introFrame,
          introFrame,
          ...real,
          introFrame,
          introFrame,
        ];
        final result = const DtwAligner()
            .align(real, target, openBegin: true, openEnd: true);
        expect(result.path.first, (0, 2));
        expect(result.path.last, (2, 4));
        expect(result.averageCost, closeTo(0, 1e-9));
      });

      test('closed mode (default) still forces the corners even with '
          'unmatched leading content present', () {
        final target = [introFrame, introFrame, introFrame, ...real];
        final result = const DtwAligner().align(real, target);
        expect(result.path.first, (0, 0));
        expect(result.path.last, (2, 5));
        // Forced to match intro frames against real content instead of
        // skipping them — this is the exact distortion open boundaries fix.
        expect(result.averageCost, greaterThan(0.3));
      });

      test('opening boundaries never increases cost versus the closed path '
          'when there is no intro/outro to skip', () {
        final closed = const DtwAligner().align(real, real);
        final open = const DtwAligner()
            .align(real, real, openBegin: true, openEnd: true);
        expect(open.averageCost, lessThanOrEqualTo(closed.averageCost + 1e-9));
        expect(open.path.first, (0, 0));
        expect(open.path.last, (2, 2));
      });

      group('skip penalty calibration', () {
        // Two-dimensional unit vectors make the cosine distance exact and
        // readable: against (1, 0), the frame (cos, sin) is at distance
        // 1 - cos.
        final held = _vec([1, 0]);
        Float64List atDistance(double d) {
          final cos = 1 - d;
          return _vec([cos, math.sqrt(1 - cos * cos)]);
        }

        test('keeps a trailing run that matches better than the penalty', () {
          final reference = [held, held, held];
          final target = [...reference, atDistance(0.1), atDistance(0.1)];
          final result = const DtwAligner()
              .align(reference, target, openEnd: true);
          expect(result.path.last.$2, 4,
              reason: '0.1/frame is cheaper than the 0.18 penalty, so these '
                  'frames are worth matching');
        });

        test('drops a trailing run that matches worse than the penalty', () {
          final reference = [held, held, held];
          final target = [...reference, atDistance(0.4), atDistance(0.4)];
          final result = const DtwAligner()
              .align(reference, target, openEnd: true);
          expect(result.path.last.$2, 2,
              reason: '0.4/frame is dearer than the 0.18 penalty, so these '
                  'frames are unmatched outro');
        });

        test('a near-free penalty collapses the alignment window onto the '
            'single best-matching frame', () {
          // The regression the calibrated default guards against, and the
          // exact shape of the Galopede failure. Reference frames all pay
          // their own distance wherever they land, so skipping saves nothing
          // directly — but when declining a target frame is nearly free, the
          // path can pick the one frame that matches perfectly and stack the
          // whole reference onto it with vertical moves, discarding good
          // surrounding content. That is a 1-frame "alignment" of a 21-frame
          // recording.
          final reference = List.filled(10, held);
          final target = [
            ...List.filled(10, atDistance(0.10)),
            held,
            ...List.filled(10, atDistance(0.10)),
          ];

          final starved = const DtwAligner(skipPenaltyPerFrame: 1e-3)
              .align(reference, target, openBegin: true, openEnd: true);
          expect(starved.path.first.$2, 10);
          expect(starved.path.last.$2, 10,
              reason: 'the whole window collapses onto target frame 10');

          // At the calibrated penalty the surrounding content matches better
          // (0.10) than declining it costs (0.18), so it is all explained.
          final calibrated = const DtwAligner()
              .align(reference, target, openBegin: true, openEnd: true);
          expect(calibrated.path.first.$2, 0);
          expect(calibrated.path.last.$2, 20);
        });
      });
    });

    test('an interior unmatched stretch is routed around, leaving the '
        'reference frames on either side of it correct', () {
      // No interior-skip state exists in the DP: every reference frame must
      // be consumed and every target frame inside the matched span must be
      // traversed. A mid-recording gap is therefore crossed horizontally, at
      // real cost — expensive, but correct for anchors, because the frames
      // before and after the gap still map to the right reference frames.
      // docs/audio-sync-dtw-interior-gaps.md proposed a second DP state to
      // skip such a stretch instead; this records the behaviour that made
      // that unnecessary. Closed boundaries, so the interior is all that is
      // under test.
      final a = _vec([1, 0, 0]);
      final b = _vec([0, 1, 0]);
      final poison = _vec([0, 0, 1]);
      final reference = [a, a, b, b];
      final target = [a, a, poison, poison, poison, b, b];

      final result = const DtwAligner().align(reference, target);

      // `_targetFrameFor` reads the *first* path entry at or after a
      // reference frame, so that is what an anchor would see.
      final firstTargetFor = <int, int>{};
      for (final (r, t) in result.path) {
        firstTargetFor.putIfAbsent(r, () => t);
      }
      // Which of the two pre-gap reference frames absorbs the gap is an
      // exact tie (both routes cost 3.0), so only their side of it is
      // determinate. What matters is that the gap costs the pre-gap frames
      // and leaves the post-gap frames landing exactly right.
      expect(firstTargetFor[0], 0);
      expect(firstTargetFor[1], lessThanOrEqualTo(4));
      expect(firstTargetFor[2], 5);
      expect(firstTargetFor[3], 6);
      // Three poison frames at distance 1.0, and nothing else unmatched.
      expect(result.averageCost * result.path.length, closeTo(3.0, 1e-6));
    });
  });
}

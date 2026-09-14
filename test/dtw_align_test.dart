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
    });
  });
}

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
  });
}

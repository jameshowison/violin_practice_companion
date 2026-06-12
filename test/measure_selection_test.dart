import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/providers.dart';

void main() {
  group('MeasureSelection.afterTap', () {
    test('nothing selected → single-measure selection', () {
      final result = MeasureSelection.afterTap(null, 3);
      expect(result, const MeasureSelection(3, 3));
    });

    test('single anchor + tap higher → range anchor..tapped', () {
      final result = MeasureSelection.afterTap(const MeasureSelection(3, 3), 7);
      expect(result, const MeasureSelection(3, 7));
    });

    test('single anchor + tap lower → range min..max', () {
      final result = MeasureSelection.afterTap(const MeasureSelection(5, 5), 2);
      expect(result, const MeasureSelection(2, 5));
    });

    test('tap the same single measure → clear', () {
      final result = MeasureSelection.afterTap(const MeasureSelection(4, 4), 4);
      expect(result, isNull);
    });

    test('tap inside an existing range → clear', () {
      final result = MeasureSelection.afterTap(const MeasureSelection(2, 6), 4);
      expect(result, isNull);
    });

    test('tap a range endpoint (inside) → clear', () {
      expect(MeasureSelection.afterTap(const MeasureSelection(2, 6), 2), isNull);
      expect(MeasureSelection.afterTap(const MeasureSelection(2, 6), 6), isNull);
    });

    test('tap outside an existing range → fresh single anchor', () {
      final result = MeasureSelection.afterTap(const MeasureSelection(2, 6), 9);
      expect(result, const MeasureSelection(9, 9));
    });
  });
}

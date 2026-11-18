import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/providers.dart';

void main() {
  group('MeasureSelection.afterTap', () {
    test('nothing selected → that bar', () {
      expect(MeasureSelection.afterTap(null, 3), const MeasureSelection(3, 3));
    });

    test('another bar while one is selected → just the new bar', () {
      expect(MeasureSelection.afterTap(const MeasureSelection(3, 3), 7),
          const MeasureSelection(7, 7));
      expect(MeasureSelection.afterTap(const MeasureSelection(5, 5), 2),
          const MeasureSelection(2, 2));
    });

    test('the bar that is the whole selection → clear', () {
      expect(MeasureSelection.afterTap(const MeasureSelection(4, 4), 4), isNull);
    });

    test('inside a range → just that bar', () {
      expect(MeasureSelection.afterTap(const MeasureSelection(2, 6), 4),
          const MeasureSelection(4, 4));
    });

    test('a range endpoint → just that bar', () {
      expect(MeasureSelection.afterTap(const MeasureSelection(2, 6), 2),
          const MeasureSelection(2, 2));
      expect(MeasureSelection.afterTap(const MeasureSelection(2, 6), 6),
          const MeasureSelection(6, 6));
    });

    test('outside a range → just that bar', () {
      expect(MeasureSelection.afterTap(const MeasureSelection(2, 6), 9),
          const MeasureSelection(9, 9));
    });

    test('a one-bar section with mid-bar edges → the whole bar, not clear',
        () {
      const section = MeasureSelection(4, 4, startNote: 2, startPerf: 7);
      expect(MeasureSelection.afterTap(section, 4), const MeasureSelection(4, 4));
    });
  });

  group('MeasureSelection.spanning', () {
    test('either order gives min..max', () {
      expect(MeasureSelection.spanning(3, 7), const MeasureSelection(3, 7));
      expect(MeasureSelection.spanning(7, 3), const MeasureSelection(3, 7));
      expect(MeasureSelection.spanning(5, 5), const MeasureSelection(5, 5));
    });
  });

  group('MeasureSelection nudges', () {
    const sel = MeasureSelection(4, 6);

    test('start grows left and shrinks right', () {
      expect(sel.nudgeStart(-1, first: 1, last: 10), const MeasureSelection(3, 6));
      expect(sel.nudgeStart(1, first: 1, last: 10), const MeasureSelection(5, 6));
    });

    test('end grows right and shrinks left', () {
      expect(sel.nudgeEnd(1, first: 1, last: 10), const MeasureSelection(4, 7));
      expect(sel.nudgeEnd(-1, first: 1, last: 10), const MeasureSelection(4, 5));
    });

    test('clamped to the piece', () {
      const edges = MeasureSelection(1, 10);
      expect(edges.nudgeStart(-1, first: 1, last: 10), edges);
      expect(edges.nudgeEnd(1, first: 1, last: 10), edges);
      // A pickup bar 0 is a real bar to grow into.
      expect(edges.nudgeStart(-1, first: 0, last: 10),
          const MeasureSelection(0, 10));
    });

    test('never shrinks below one bar', () {
      const one = MeasureSelection(5, 5);
      expect(one.nudgeStart(1, first: 1, last: 10), one);
      expect(one.nudgeEnd(-1, first: 1, last: 10), one);
    });

    test('a nudged section becomes whole bars', () {
      const section = MeasureSelection(4, 6,
          startNote: 2, endNote: 3, startPerf: 9, endPerf: 11, skipped: {5});
      expect(section.nudgeEnd(1, first: 1, last: 10), const MeasureSelection(4, 7));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/section_run.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/widgets/section_minimap.dart';

// `|: A :| B` unfolded: A¹ and A² share bars 1–4 (different perf slices).
const _runs = [
  SectionRun(
      label: 'A', passIndex: 0, passCount: 2,
      firstMeasure: 1, lastMeasure: 4, perfStart: 0, perfEnd: 4),
  SectionRun(
      label: 'A', passIndex: 1, passCount: 2,
      firstMeasure: 1, lastMeasure: 4, perfStart: 4, perfEnd: 8),
  SectionRun(
      label: 'B', passIndex: 0, passCount: 1,
      firstMeasure: 5, lastMeasure: 8, perfStart: 8, perfEnd: 12),
];

void main() {
  group('sectionRunForDoubleTap', () {
    test('a bar of a repeated section picks the first pass', () {
      expect(sectionRunForDoubleTap(_runs, 2, null), 0);
      expect(sectionRunForDoubleTap(_runs, 2, const MeasureSelection(2, 2)),
          0);
    });

    test('double-tapping again walks the passes and wraps', () {
      final a1 = MeasureSelection.ofRun(_runs[0]);
      final a2 = MeasureSelection.ofRun(_runs[1]);
      expect(sectionRunForDoubleTap(_runs, 3, a1), 1);
      expect(sectionRunForDoubleTap(_runs, 3, a2), 0);
    });

    test('a different section selected before → that bar\'s first pass', () {
      final b = MeasureSelection.ofRun(_runs[2]);
      expect(sectionRunForDoubleTap(_runs, 1, b), 0);
      expect(sectionRunForDoubleTap(_runs, 6, null), 2);
    });

    test('no section holds the bar → null (falls back to a plain tap)', () {
      expect(sectionRunForDoubleTap(const [], 3, null), isNull);
      expect(sectionRunForDoubleTap(_runs, 9, null), isNull);
    });
  });
}

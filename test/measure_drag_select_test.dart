import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/verovio_engraver.dart';
import 'package:violin_practice_companion/widgets/measure_drag_select.dart';
import 'package:violin_practice_companion/widgets/staff_view_verovio.dart';

/// Rows of four 80×60 bars, numbered from 1, in a vertical scroll view.
Widget _harness({
  required ScrollController controller,
  required void Function(int, int) onRange,
  ValueChanged<int>? onTap,
  List<bool>? dragging,
  int rows = 20,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: Builder(
            builder: (context) => MeasureDragSelect(
              controller: controller,
              measureAt: (g) => measureTagAt(context, g),
              onRange: onRange,
              onDragging: (on) => dragging?.add(on),
              child: SingleChildScrollView(
                controller: controller,
                child: Column(children: [
                  for (var r = 0; r < rows; r++)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      for (var c = 0; c < 4; c++)
                        MeasureTag(
                          number: r * 4 + c + 1,
                          child: GestureDetector(
                            onTap: () => onTap?.call(r * 4 + c + 1),
                            child: SizedBox(
                              key: ValueKey('bar${r * 4 + c + 1}'),
                              width: 80,
                              height: 60,
                              child: const ColoredBox(color: Colors.white),
                            ),
                          ),
                        ),
                    ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('MeasureDragSelect', () {
    testWidgets('hold then slide selects from the held bar, across rows',
        (tester) async {
      final ranges = <(int, int)>[];
      final dragging = <bool>[];
      final c = ScrollController();
      await tester.pumpWidget(_harness(
          controller: c, onRange: (a, b) => ranges.add((a, b)),
          dragging: dragging));
      final g = await tester
          .startGesture(tester.getCenter(find.byKey(const ValueKey('bar2'))));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(ranges, [(2, 2)]);
      // Down a row and right a bar: bar 7.
      await g.moveBy(const Offset(80, 60));
      await tester.pump();
      expect(ranges.last, (2, 7));
      await g.up();
      await tester.pump();
      expect(dragging, [true, false]);
      expect(c.offset, 0, reason: 'the hold owns the pointer; no scroll');
    });

    testWidgets('a plain drag scrolls and selects nothing', (tester) async {
      final ranges = <(int, int)>[];
      final taps = <int>[];
      final c = ScrollController();
      await tester.pumpWidget(_harness(
          controller: c,
          onRange: (a, b) => ranges.add((a, b)),
          onTap: taps.add));
      await tester.drag(
          find.byKey(const ValueKey('bar6')), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(c.offset, greaterThan(0));
      expect(ranges, isEmpty);
      expect(taps, isEmpty);
    });

    testWidgets('a quick tap is a tap, not a range', (tester) async {
      final ranges = <(int, int)>[];
      final taps = <int>[];
      final c = ScrollController();
      await tester.pumpWidget(_harness(
          controller: c,
          onRange: (a, b) => ranges.add((a, b)),
          onTap: taps.add));
      await tester.tap(find.byKey(const ValueKey('bar3')));
      await tester.pumpAndSettle();
      expect(taps, [3]);
      expect(ranges, isEmpty);
    });

    testWidgets('resting at the bottom edge scrolls and extends the range',
        (tester) async {
      final ranges = <(int, int)>[];
      final c = ScrollController();
      await tester.pumpWidget(_harness(
          controller: c, onRange: (a, b) => ranges.add((a, b))));
      final g = await tester
          .startGesture(tester.getCenter(find.byKey(const ValueKey('bar1'))));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      // Into the bottom edge zone (the view is 400 tall) and hold still.
      await g.moveTo(const Offset(40, 395));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(c.offset, greaterThan(0));
      final (anchor, current) = ranges.last;
      expect(anchor, 1);
      expect(current, greaterThan(25), reason: 'past the first screenful');
      await g.up();
      await tester.pump();
    });
  });

  group('measureIndexAtPoint', () {
    // Two lines of two bars; ink boxes leave gaps, the bands tile.
    final score = EngravedScore(
      viewBox: const Size(200, 200),
      svg: '',
      bboxById: const {},
      measures: const [
        MeasureAnchor(index: 0, id: 'm0', rect: Rect.fromLTRB(10, 30, 100, 70)),
        MeasureAnchor(index: 1, id: 'm1', rect: Rect.fromLTRB(100, 30, 190, 70)),
        MeasureAnchor(index: 2, id: 'm2', rect: Rect.fromLTRB(10, 130, 100, 170)),
        MeasureAnchor(index: 3, id: 'm3', rect: Rect.fromLTRB(100, 130, 190, 170)),
      ],
      notes: const [],
      measureLine: const [0, 0, 1, 1],
      lineBands: const [(top: 20, bottom: 100), (top: 100, bottom: 180)],
      lineContent: const [(top: 30, bottom: 70), (top: 130, bottom: 170)],
      pageWidthUnits: 2000,
      renderMs: 0,
    );

    test('inside a bar', () {
      expect(measureIndexAtPoint(score, const Offset(50, 50)), 0);
      expect(measureIndexAtPoint(score, const Offset(150, 150)), 3);
    });

    test('between systems, by the band', () {
      expect(measureIndexAtPoint(score, const Offset(150, 90)), 1);
      expect(measureIndexAtPoint(score, const Offset(50, 110)), 2);
    });

    test('above the first or below the last system', () {
      expect(measureIndexAtPoint(score, const Offset(150, 5)), 1);
      expect(measureIndexAtPoint(score, const Offset(50, 199)), 2);
    });

    test('past a line end, the nearest bar on that line', () {
      expect(measureIndexAtPoint(score, const Offset(2, 50)), 0);
      expect(measureIndexAtPoint(score, const Offset(198, 150)), 3);
    });
  });
}

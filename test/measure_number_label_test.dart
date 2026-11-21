import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/engraved_measure_map.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:score_view/score_view.dart';
import 'package:violin_practice_companion/widgets/staff_view_verovio.dart';

/// The measure-number labels on a selection: which bars get one, where the
/// staff's top line is, and where on it the label sits.
void main() {
  group('measureStaffLines', () {
    // Real Verovio output (svgBoundingBoxes on), the same fixture as
    // verovio_bbox_test.dart.
    final svg = File('test/fixtures/verovio_bbox.svg').readAsStringSync();

    test('one top line per measure, in viewBox px', () {
      final lines = VerovioEngraver.measureStaffLines(svg)!;
      expect(lines.length, 'class="measure">'.allMatches(svg).length);
      // First bar: `M1381 775 L3592 775` in inner units, mapped through the
      // page's own viewBox and page-margin translate.
      final root = RegExp(r'<svg[^>]*viewBox="0 0 ([\d.]+)').firstMatch(svg)!;
      final inner = RegExp(
              r'class="definition-scale"[^>]*viewBox="0 0 ([\d.]+)')
          .firstMatch(svg)!;
      final t = RegExp(r'class="page-margin" transform="translate\((-?[\d.]+), (-?[\d.]+)\)"')
          .firstMatch(svg)!;
      final f = double.parse(root.group(1)!) / double.parse(inner.group(1)!);
      final dx = double.parse(t.group(1)!), dy = double.parse(t.group(2)!);
      expect(lines[0].top, closeTo((775 + dy) * f, 1e-9));
      expect(lines[0].left, closeTo((1381 + dx) * f, 1e-9));
      expect(lines[0].right, closeTo((3592 + dx) * f, 1e-9));
      // Bars on one system tile: each starts where the last one ended.
      expect(lines[1].left, closeTo(lines[0].right, 1e-9));
      expect(lines[1].top, lines[0].top);
    });

    test('a later system sits lower', () {
      final lines = VerovioEngraver.measureStaffLines(svg)!;
      expect(lines.last.top, greaterThan(lines.first.top));
    });

    test('null without measures', () {
      expect(VerovioEngraver.measureStaffLines('<svg></svg>'), isNull);
    });
  });

  test('staffLines survive the disk cache round trip', () {
    const score = EngravedScore(
      viewBox: Size(100, 100),
      svg: '',
      bboxById: {},
      measures: [],
      notes: [],
      measureLine: [],
      lineBands: [],
      lineContent: [],
      pageWidthUnits: 1000,
      renderMs: 0,
      staffLines: [(top: 12.5, left: 3, right: 40)],
    );
    final back = EngravedScore.fromJson(score.toJson());
    expect(back.staffLineAt(0), (top: 12.5, left: 3.0, right: 40.0));
    expect(back.staffLineAt(1), isNull);
  });

  group('selectionLabelMeasures', () {
    final map = EngravedMeasureMap.identity([1, 2, 3, 4, 5, 6]);

    test('one bar → one label', () {
      expect(selectionLabelMeasures(map, const MeasureSelection(3, 3)),
          [(index: 2, number: 3)]);
    });

    test('a range → its first and last bar', () {
      expect(selectionLabelMeasures(map, const MeasureSelection(2, 5)),
          [(index: 1, number: 2), (index: 4, number: 5)]);
    });

    test('an exclusive end on note 0 labels the bar before', () {
      expect(
          selectionLabelMeasures(
              map, const MeasureSelection(2, 5, endNote: 0)),
          [(index: 1, number: 2), (index: 3, number: 4)]);
    });

    test('a split last bar is labelled on its first slice in range', () {
      const split = EngravedMeasureMap([
        (number: 1, noteOffset: 0),
        (number: 2, noteOffset: 0),
        (number: 2, noteOffset: 2),
        (number: 3, noteOffset: 0),
      ]);
      expect(selectionLabelMeasures(split, const MeasureSelection(1, 2)),
          [(index: 0, number: 1), (index: 1, number: 2)]);
      // Both slices of one bar are one bar.
      expect(selectionLabelMeasures(split, const MeasureSelection(2, 2)),
          [(index: 1, number: 2)]);
    });

    test('not engraved → nothing', () {
      expect(selectionLabelMeasures(map, const MeasureSelection(9, 9)),
          isEmpty);
    });
  });

  test('label origin: inset from the barline, baseline above the top line',
      () {
    const space = 10.0;
    final at = measureNumberLabelOrigin(
        barLeft: 100, staffTop: 50, space: space, baseline: 8);
    expect(at.dx, 100 + space * measureNumberInset);
    // The baseline (origin + 8) sits measureNumberLift spaces above the line.
    expect(at.dy + 8, 50 - space * measureNumberLift);
  });

  test("a system's first bar: pushed past the key signature to its first note",
      () {
    const space = 10.0;
    final at = measureNumberLabelOrigin(
        barLeft: 0,
        staffTop: 50,
        space: space,
        baseline: 8,
        firstNoteLeft: 40,
        textWidth: 6);
    expect(at.dx + 6, 40 - space * measureNumberNoteGap);
    // A first note hard by the barline never pulls the label left of its
    // usual place.
    final tight = measureNumberLabelOrigin(
        barLeft: 0,
        staffTop: 50,
        space: space,
        baseline: 8,
        firstNoteLeft: 4,
        textWidth: 6);
    expect(tight.dx, space * measureNumberInset);
  });
}

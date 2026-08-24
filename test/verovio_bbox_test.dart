import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/verovio_engraver.dart';

/// Verovio's own `svgBoundingBoxes` output, which is where a system's real ink
/// extent comes from. See [VerovioEngraver.systemInkBoxes] for why the hit map's
/// measure union is not usable for this.
void main() {
  // A minimal page with the same coordinate chain a real engrave has: a root
  // viewBox, a `definition-scale` inner viewBox ten times its size, and a
  // `page-margin` translate. Hand-written so the expected numbers are exact
  // rather than "about right".
  const synthetic = '''
<svg viewBox="0 0 100 200" version="1.1" id="root">
  <svg class="definition-scale" color="black" viewBox="0 0 1000 2000">
    <g class="page-margin" transform="translate(50, 60)">
      <g id="s1" class="system">
        <g id="bbox-s1" class="system bounding-box" />
        <g id="bbox-n1" class="note bounding-box"><rect x="10" y="100" height="40" width="20" fill="transparent"/></g>
        <g id="bbox-st1" class="stem bounding-box"><rect x="10" y="130" height="70" width="4" fill="transparent"/></g>
      </g>
      <g id="s2" class="system">
        <g id="bbox-s2" class="system bounding-box" />
        <g id="bbox-n2" class="note bounding-box"><rect x="10" y="500" height="40" width="20" fill="transparent"/></g>
      </g>
    </g>
  </svg>
</svg>''';

  group('systemInkBoxes coordinate chain', () {
    test('unions the leaf boxes and maps inner units to viewBox px', () {
      final boxes = VerovioEngraver.systemInkBoxes(synthetic);
      expect(boxes, isNotNull);
      expect(boxes!.length, 2);
      // factor = 100/1000 = 0.1, translateY = 60.
      // system 0 spans y 100 (note top) .. 200 (stem bottom, 130 + 70).
      expect(boxes[0].top, closeTo((100 + 60) * 0.1, 1e-9));
      expect(boxes[0].bottom, closeTo((130 + 70 + 60) * 0.1, 1e-9));
      expect(boxes[1].top, closeTo((500 + 60) * 0.1, 1e-9));
      expect(boxes[1].bottom, closeTo((500 + 40 + 60) * 0.1, 1e-9));
    });

    test('the page-margin translate is applied, not ignored', () {
      // Same page with no translate: every edge moves up by 60 inner units.
      final noTranslate = synthetic.replaceAll(
        'transform="translate(50, 60)"',
        'transform="translate(0, 0)"',
      );
      final with_ = VerovioEngraver.systemInkBoxes(synthetic)!;
      final without = VerovioEngraver.systemInkBoxes(noTranslate)!;
      expect(with_[0].top - without[0].top, closeTo(6.0, 1e-9));
      // ...but the GAP between systems is unaffected, which is why a
      // difference-only measurement can miss a wrong translate entirely.
      expect(
        with_[1].top - with_[0].bottom,
        closeTo(without[1].top - without[0].bottom, 1e-9),
      );
    });

    test('the container boxes Verovio emits empty contribute nothing', () {
      // `system bounding-box` carries no rect; dropping it changes no edge.
      final withoutContainers = synthetic
          .replaceAll('<g id="bbox-s1" class="system bounding-box" />', '')
          .replaceAll('<g id="bbox-s2" class="system bounding-box" />', '');
      expect(
        VerovioEngraver.systemInkBoxes(withoutContainers),
        VerovioEngraver.systemInkBoxes(synthetic),
      );
    });

    test('null when the SVG carries no boxes, so callers can fall back', () {
      // The fixtures recorded before `svgBoundingBoxes` was turned on.
      final plain = File('test/fixtures/verovio_fing.svg').readAsStringSync();
      expect(plain.contains('bounding-box'), isFalse);
      expect(VerovioEngraver.systemInkBoxes(plain), isNull);
    });

    test('does not mistake `systemMilestoneEnd` for a system', () {
      final withMilestone = synthetic.replaceFirst(
        '<g id="s2" class="system">',
        '<g id="m1" class="systemMilestoneEnd s1" />\n      '
            '<g id="s2" class="system">',
      );
      expect(VerovioEngraver.systemInkBoxes(withMilestone)!.length, 2);
    });
  });

  group('a real engrave', () {
    // Old Joe Clark, fingerings injected and harmony kept, engraved at the
    // options the app uses. `<defs>` stripped for size; the parser never reads
    // it.
    late String svg;
    setUpAll(() {
      svg = File('test/fixtures/verovio_bbox.svg').readAsStringSync();
    });

    test('one box per system, ordered and non-overlapping', () {
      final boxes = VerovioEngraver.systemInkBoxes(svg)!;
      expect(boxes.length, 3);
      for (final b in boxes) {
        expect(b.bottom, greaterThan(b.top));
      }
      for (var i = 1; i < boxes.length; i++) {
        // A real gap, and the systems do not interleave.
        expect(boxes[i].top, greaterThan(boxes[i - 1].bottom));
      }
    });

    test('the systems are evenly spaced and evenly tall', () {
      // Three systems of the same tune at one spacingSystem: Verovio has no
      // reason to treat them differently, and a parser that mixed up two
      // coordinate spaces would not produce this.
      final boxes = VerovioEngraver.systemInkBoxes(svg)!;
      final heights = [for (final b in boxes) b.bottom - b.top];
      final gaps = [
        for (var i = 1; i < boxes.length; i++) boxes[i].top - boxes[i - 1].bottom,
      ];
      for (final h in heights) {
        expect(h, closeTo(heights.first, 1.0));
      }
      for (final g in gaps) {
        expect(g, closeTo(gaps.first, 1.0));
      }
    });

    test('the whole page is accounted for, and nothing sits outside it', () {
      final boxes = VerovioEngraver.systemInkBoxes(svg)!;
      final height = double.parse(
        RegExp(r'<svg[^>]*viewBox="0 0 [\d.]+ ([\d.]+)"')
            .firstMatch(svg)!
            .group(1)!,
      );
      expect(boxes.first.top, greaterThanOrEqualTo(0));
      expect(boxes.last.bottom, lessThanOrEqualTo(height));
      // The ink does not fill the page: there are margins and inter-system gaps.
      expect(boxes.last.bottom, lessThan(height));
    });
  });

  group('stripBoundingBoxes', () {
    test('removes every box group, both shapes, and leaves the content', () {
      final svg = File('test/fixtures/verovio_bbox.svg').readAsStringSync();
      expect(RegExp(r'<g id="bbox-').allMatches(svg).length, 523);

      final stripped = VerovioEngraver.stripBoundingBoxes(svg);
      expect(stripped.contains('bbox-'), isFalse);
      expect(stripped.contains('bounding-box'), isFalse);
      // The real content is untouched: same systems, same notes, same
      // annotations to read anchors off.
      for (final cls in ['class="system">', 'class="note"', 'class="fing"']) {
        expect(
          RegExp(RegExp.escape(cls)).allMatches(stripped).length,
          RegExp(RegExp.escape(cls)).allMatches(svg).length,
          reason: cls,
        );
      }
      expect(stripped.length, lessThan(svg.length));
      // Still a balanced document: as many <g opens as </g> closes.
      expect(
        RegExp(r'<g[ >]').allMatches(stripped).length -
            RegExp(r'<g[^>]*/>').allMatches(stripped).length,
        RegExp(r'</g>').allMatches(stripped).length,
      );
    });

    test('a no-op on an SVG that never had any', () {
      final plain = File('test/fixtures/verovio_fing.svg').readAsStringSync();
      expect(VerovioEngraver.stripBoundingBoxes(plain), plain);
    });
  });
}

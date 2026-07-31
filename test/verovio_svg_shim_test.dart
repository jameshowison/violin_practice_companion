import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/verovio_engraver.dart';

/// `VerovioEngraver.flattenForRenderer` is the jovial_svg shim. These cover the
/// stylesheet un-scoping, which is what makes staff lines, stems and barlines
/// visible — see the method docs for why.
void main() {
  group('stylesheet un-scoping', () {
    // Verovio's real output, trimmed. Note the staff line carries no stroke of
    // its own: the stylesheet is the only thing that draws it.
    String svgWith(String styleBody) => '''
<svg viewBox="0 0 988 293" id="jspm2ir">
<style type="text/css">$styleBody</style>
<defs><symbol id="E050-jspm2ir" viewBox="0 0 1000 1000"></symbol></defs>
<svg class="definition-scale" color="black" viewBox="0 0 24700 7320">
<g class="page-margin">
<path d="M0 640 L4701 640" stroke-width="13" />
<use xlink:href="#E050-jspm2ir" transform="translate(90, 1180)" />
</g>
</svg>
</svg>
''';

    test('an ID-scoped element selector becomes a bare element selector', () {
      final out = VerovioEngraver.flattenForRenderer(
          svgWith('#jspm2ir path {stroke:currentColor}'));
      expect(out, contains('path {stroke:currentColor}'));
      expect(out, isNot(contains('#jspm2ir path')));
    });

    test('every selector in a comma list is un-scoped', () {
      final out = VerovioEngraver.flattenForRenderer(svgWith(
          '#jspm2ir ellipse, #jspm2ir path, #jspm2ir polygon, '
          '#jspm2ir polyline, #jspm2ir rect {stroke:currentColor}'));
      expect(out, contains('ellipse, path, polygon, polyline, rect'));
      expect(out, isNot(contains('#jspm2ir ellipse')));
    });

    test('element.class selectors keep their class', () {
      // jovial splits a selector on '.', so `g.dir` is element `g`, class `dir`.
      final out = VerovioEngraver.flattenForRenderer(
          svgWith('#jspm2ir g.dir, #jspm2ir g.dynam {font-style:italic;}'));
      expect(out, contains('g.dir, g.dynam {font-style:italic;}'));
    });

    test('glyph references OUTSIDE the style block are untouched', () {
      // The load-bearing constraint: `xlink:href="#E050-jspm2ir"` and the
      // symbol id must survive, or every notehead disappears.
      final out = VerovioEngraver.flattenForRenderer(
          svgWith('#jspm2ir path {stroke:currentColor}'));
      expect(out, contains('xlink:href="#E050-jspm2ir"'));
      expect(out, contains('id="E050-jspm2ir"'));
      expect(out, contains('id="jspm2ir"'));
    });

    test('an SVG with no style block is passed through unharmed', () {
      const svg = '<svg viewBox="0 0 10 10" id="x">'
          '<path d="M0 0 L10 0" stroke-width="1" /></svg>';
      expect(VerovioEngraver.flattenForRenderer(svg), contains('<path'));
    });
  });

  group('nested svg flattening', () {
    test('the inner definition-scale svg collapses to a scaling <g>', () {
      const svg = '<svg viewBox="0 0 988 293" id="i">'
          '<svg class="definition-scale" viewBox="0 0 24700 7320">'
          '<path d="M0 0 L1 1" /></svg></svg>';
      final out = VerovioEngraver.flattenForRenderer(svg);
      // jovial throws on a second <svg> tag, so exactly one must remain.
      expect(RegExp(r'<svg\b').allMatches(out).length, 1);
      expect(out, contains('<g transform="scale('));
      // 988/24700 = 0.04
      expect(out, contains('scale(0.040000, 0.040027)'));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/widgets/section_minimap.dart';

// Split from staff_zoom_test when staff_zoom moved into score_view: the
// minimap is an app widget, and this pins its width beside the marker scale
// (`sectionMarkerScaleFor`).
void main() {
  group('sectionMarkerScaleFor', () {
    test('the minimap strip width does NOT depend on the marker scale', () {
      // The load-bearing invariant: the strip is a Row sibling of the notation,
      // so a zoom-dependent width would close a positive feedback loop (wider
      // strip → narrower notation → auto picks fewer measures per line → bigger
      // markers → wider strip). Observed cascading 6 → 4 → 3 across three extra
      // engraves before the width was pinned. A plain const is the guarantee.
      expect(SectionMinimap.width, isA<double>());
      expect(SectionMinimap.width, 44);
    });
  });
}

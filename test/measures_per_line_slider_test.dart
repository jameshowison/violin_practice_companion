// Regression test: a Slider with min == max cannot claim drag gestures, causing
// drags to leak to parent handlers (e.g. the settings Drawer's swipe-to-close).
// Mirrors staff_spacing_slider_test.dart, which caught exactly that in Jun 2026.
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';

void main() {
  group('measuresPerLine slider constants', () {
    test('min is strictly less than max so the Slider can claim drag gestures', () {
      expect(measuresPerLineMin, lessThan(measuresPerLineMax));
    });

    test('divisions land on whole measures', () {
      // The slider uses `max - min` divisions to snap to integers; that only
      // works while both bounds are ints, which the types already guarantee —
      // this asserts the count is usable (non-zero).
      expect(measuresPerLineMax - measuresPerLineMin, greaterThan(0));
    });

    test('the width fallback is a valid slider position', () {
      expect(measuresPerLineForWidth(1024), greaterThanOrEqualTo(measuresPerLineMin));
      expect(measuresPerLineForWidth(1024), lessThanOrEqualTo(measuresPerLineMax));
    });
  });
}

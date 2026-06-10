// Regression test: a Slider with min == max cannot claim drag gestures, causing
// drags to leak to parent handlers (e.g. a Drawer's swipe-to-close).
// Caught by: setting staffSpacingMin == staffSpacingMax == 0.5 in Jun 2026.
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/providers.dart';

void main() {
  group('staffSpacingProvider constants', () {
    test('min is strictly less than max so the Slider can claim drag gestures', () {
      expect(staffSpacingMin, lessThan(staffSpacingMax));
    });

    test('default value is within [min, max]', () {
      expect(staffSpacingDefault, greaterThanOrEqualTo(staffSpacingMin));
      expect(staffSpacingDefault, lessThanOrEqualTo(staffSpacingMax));
    });
  });
}

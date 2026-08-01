import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/chord_palette.dart';

void main() {
  group('ChordPalette', () {
    test('every degree has a distinct swatch except the hatched III', () {
      expect(ChordPalette.byDegree.length, 7);
      // III shares II's green because it is drawn hatched over [iiiAlt] rather
      // than given a hue of its own — so exactly one duplicate is expected.
      expect(ChordPalette.byDegree.toSet().length, 6);
      expect(ChordPalette.byDegree[ChordPalette.hatchedDegree],
          ChordPalette.byDegree[1]);
    });

    test('the minor shade is darker than the major shade, same hue', () {
      for (var d = 0; d < ChordPalette.byDegree.length; d++) {
        final major = ChordPalette.of(d);
        final minor = ChordPalette.of(d, minor: true);
        expect(minor.computeLuminance(), lessThan(major.computeLuminance()),
            reason: 'degree $d minor should be dimmer');
        // Tolerance absorbs the 8-bit round trip through Color, not a hue shift.
        expect(HSLColor.fromColor(minor).hue,
            closeTo(HSLColor.fromColor(major).hue, 1.0),
            reason: 'degree $d must keep its hue when dimmed');
      }
    });

    test('an unknown or out-of-range degree falls back to grey', () {
      expect(ChordPalette.of(null), ChordPalette.unknown);
      expect(ChordPalette.of(-1), ChordPalette.unknown);
      expect(ChordPalette.of(7), ChordPalette.unknown);
    });

    test('label ink flips to stay readable across the palette', () {
      // Parchment (I) and yellow (V) are light; blue (VI) and red (IV) are not.
      expect(ChordPalette.inkOn(ChordPalette.of(0)).computeLuminance(),
          lessThan(0.5));
      expect(ChordPalette.inkOn(ChordPalette.of(4)).computeLuminance(),
          lessThan(0.5));
      expect(ChordPalette.inkOn(ChordPalette.of(5)).computeLuminance(),
          greaterThan(0.5));
      expect(ChordPalette.inkOn(ChordPalette.of(3)).computeLuminance(),
          greaterThan(0.5));
    });
  });
}

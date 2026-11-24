import 'dart:ui' show Brightness, Color;

import 'recorder_fingering.dart';

/// The colour lane's colours for a wind's [FingeringGroup]s, from the
/// woodwind mockup (family-plan branch, `woodwind-fingering-lane.html`):
/// teal for the left hand alone, amber for both hands, magenta for the thumb
/// off or half-holed, each lifted for a dark page. A flute's overblown
/// octave shares the thumb's magenta: both mean "the upper register now".
Color fingeringGroupColor(FingeringGroup g, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (g) {
    FingeringGroup.leftHand =>
      dark ? const Color(0xFF3FB7BC) : const Color(0xFF138A8F),
    FingeringGroup.bothHands =>
      dark ? const Color(0xFFE0A83A) : const Color(0xFFC98A12),
    FingeringGroup.thumbOff || FingeringGroup.overblown =>
      dark ? const Color(0xFFD965A8) : const Color(0xFFB0367F),
  };
}

/// What each group means, for a legend.
String fingeringGroupLabel(FingeringGroup g) => switch (g) {
      FingeringGroup.leftHand => 'Left hand only',
      FingeringGroup.bothHands => 'Both hands',
      FingeringGroup.thumbOff => 'Thumb off',
      FingeringGroup.overblown => 'High octave',
    };

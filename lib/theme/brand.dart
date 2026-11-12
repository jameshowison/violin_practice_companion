import 'dart:ui' show Color;

/// The paper the app icon is drawn on (the top of its gradient, `bg1` in
/// scripts/app_icon/stringlings_icon.mjs). The launch screens, the splash and
/// the Playful skin's page background share it. Classic keeps iOS's grouped
/// grey: tried on paper, its blue and white didn't sit with it.
const kIconPaper = Color(0xFFFFF9EE);

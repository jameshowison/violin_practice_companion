import 'package:flutter/painting.dart';

import 'piece_library.dart';
import 'section_palette.dart';

/// One colour per collection, for the filter chips' dots.
///
/// Reuses [SectionPalette.swatches] rather than defining its own — the seven
/// hues are already tuned to be distinct and muted against the indigo scheme,
/// and a second, subtly-different set of "identity colours" in the same app
/// would read as a mistake. Sibling of `section_palette.dart` and
/// `chord_palette.dart`.
class CollectionPalette {
  /// Collection ID → colour, assigned in display order and wrapping past seven.
  ///
  /// Keyed by ID, not name, so renaming a collection doesn't recolour it.
  static Map<String, Color> colorsFor(List<Collection> collections) {
    final map = <String, Color>{};
    for (var i = 0; i < collections.length; i++) {
      map[collections[i].id] =
          SectionPalette.swatches[i % SectionPalette.swatches.length];
    }
    return map;
  }
}

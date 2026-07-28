import '../models/chord_shape.dart';

/// Lookup from chord name (as produced by `MusicXmlParser`, e.g. `A`, `E7`) to a
/// mandolin GDAE fingering.
///
/// ⚠️ PROVISIONAL DATA. The shapes below are musically correct for GDAE tuning
/// but are placeholders for the beginner-mandolin **ebook** shapes the feature
/// is meant to echo. Replace the values in [_shapes] with the exact ebook
/// fingerings (fret + finger per course, low→high `[G, D, A, E]`); the diagram
/// renderer and footer block already consume whatever is here.
class ChordShapeLibrary {
  static const _shapes = <String, ChordShape>{
    // [G, D, A, E]  (0 = open, null = muted)
    'A':  ChordShape('A',  [2, 2, 4, 0]), // A C# E  — provisional
    'E7': ChordShape('E7', [1, 0, 2, 0]), // G# D B E — provisional
  };

  static ChordShape? lookup(String name) => _shapes[name];

  /// Whether we have a drawable shape for [name].
  static bool has(String name) => _shapes.containsKey(name);
}

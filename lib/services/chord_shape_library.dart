import '../models/chord_shape.dart';

/// Lookup from chord name (as produced by `MusicXmlParser`, e.g. `A`, `Em`) to a
/// mandolin GDAE fingering.
///
/// Source: the "Beginner Chord Index" (David Benedict) — `docs/beginner_chord_index.pdf`.
/// Frets are `[G, D, A, E]` low→high; `0` = open, `null` = muted. The chart draws
/// no finger numbers, so [ChordShape.fingers] is left null. Note the chart's A and
/// E are deliberately open-fifth voicings (no 3rd) — beginner-friendly drones.
///
/// These 9 triads have no dominant-7th shapes (E7/D7/G7/A7) and no B/F♯m/etc.
class ChordShapeLibrary {
  static const _shapes = <String, ChordShape>{
    // [G, D, A, E]
    'G':  ChordShape('G',  [0, 0, 2, 3]),
    'C':  ChordShape('C',  [0, 2, 3, 0]),
    'D':  ChordShape('D',  [2, 0, 0, 2]),
    'A':  ChordShape('A',  [2, 2, 0, 0]),
    'E':  ChordShape('E',  [4, 2, 2, 0]),
    'Dm': ChordShape('Dm', [2, 0, 0, 1]),
    'Am': ChordShape('Am', [2, 2, 3, 0]),
    'Em': ChordShape('Em', [0, 2, 2, 0]),
    'F':  ChordShape('F',  [5, 0, 3, 1]),
  };

  static ChordShape? lookup(String name) => _shapes[name];

  /// Whether we have a drawable shape for [name].
  static bool has(String name) => _shapes.containsKey(name);
}

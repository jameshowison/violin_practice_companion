/// A chord fingering for mandolin standard tuning (GDAE, 4 courses).
///
/// [frets] holds one entry per course, ordered **low → high**: `[G, D, A, E]`.
/// A value of `0` means the open course, a positive int is the fret, and `null`
/// means the course is not played (muted). [fingers], when given, is the same
/// length and order (`0`/`null` = open/none). Barre chords use [baseFret] as
/// the leftmost fret shown (1 = nut position).
///
/// Rendering order is high → low (E on top) to match the tab stave — see
/// `ChordDiagram`.
class ChordShape {
  final String name;
  final List<int?> frets; // length 4, [G, D, A, E] low→high
  final List<int?>? fingers;
  final int baseFret;

  const ChordShape(this.name, this.frets, {this.fingers, this.baseFret = 1});

  /// Highest fretted position (0 if all open/muted). Drives the fret-window size.
  int get maxFret =>
      frets.whereType<int>().fold(0, (m, f) => f > m ? f : m);
}

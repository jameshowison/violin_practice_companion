/// A clef, as MusicXML writes it: `<sign>`, `<line>` and
/// `<clef-octave-change>`.
class Clef {
  /// `G`, `F`, `C`, `percussion`, `TAB` or `none`.
  final String sign;

  /// The staff line the sign sits on, counted from the bottom (1–5). When a
  /// score leaves it out, the MusicXML default for the sign: 2 for G, 4 for
  /// F, 3 for C, and 0 for a sign that has no line.
  final int line;

  /// Octaves the music sounds from what the clef alone says: -1 for the
  /// treble-8vb clef a tenor part or a guitar is written in, 0 for most.
  final int octaveChange;

  const Clef(this.sign, this.line, {this.octaveChange = 0});

  static const treble = Clef('G', 2);
  static const alto = Clef('C', 3);
  static const tenor = Clef('C', 4);
  static const bass = Clef('F', 4);

  /// The line a [sign] sits on when a score doesn't say.
  static int defaultLine(String sign) =>
      switch (sign) { 'G' => 2, 'C' => 3, 'F' => 4, _ => 0 };

  @override
  bool operator ==(Object other) =>
      other is Clef &&
      other.sign == sign &&
      other.line == line &&
      other.octaveChange == octaveChange;

  @override
  int get hashCode => Object.hash(sign, line, octaveChange);

  @override
  String toString() =>
      '$sign$line${octaveChange == 0 ? '' : (octaveChange > 0 ? '+$octaveChange' : '$octaveChange')}';
}

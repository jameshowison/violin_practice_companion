/// The GDAE tuning shared by the violin and the mandolin.
///
/// That shared tuning is the whole reason one calculation serves both
/// instruments: a note's mandolin fret is just its distance above whichever open
/// string it sits on, and the strings are the same four. So the tab staff and the
/// annotation view's fingering channel resolve string+fret through here rather
/// than each carrying its own copy of the open-string table.
class GdaeTuning {
  GdaeTuning._();

  /// Open-string MIDI numbers. Must agree with
  /// `assets/lookup_tables/fingering_first_position.json`, which is what
  /// [FingeringMapper] keys the violin fingerings off.
  static const openMidi = {'E': 76, 'A': 69, 'D': 62, 'G': 55};

  /// String letter → tab string number (1 = top line = E, 4 = bottom = G).
  static const stringNumber = {'E': 1, 'A': 2, 'D': 3, 'G': 4};

  /// Highest string on which [midi] plays at a first-position fret (≤6).
  ///
  /// "Highest" keeps frets low, which is the beginner-friendly reading — A4 comes
  /// out as the open A rather than fret 7 on the D string.
  ///
  /// Notes with no such string fall back to the nearest end of the range, which
  /// is why "≤6" is a preference and not a guarantee: above the E string's 6th
  /// fret there is no higher string to move to, so the top of the fingering
  /// table (B5, the E string's 4th finger) still comes out at fret 7.
  static String stringFor(int midi) {
    for (final s in const ['E', 'A', 'D', 'G']) {
      final fret = midi - openMidi[s]!;
      if (fret >= 0 && fret <= 6) return s;
    }
    return midi >= openMidi['E']! ? 'E' : 'G';
  }

  /// The string [midi] is played on and the fret it lands at.
  ///
  /// [fingerString] is the violin fingering's own string (`NoteEvent
  /// .fingerString`). When [preferOpenFrets] it is ignored in favour of
  /// [stringFor], so frets stay ≤6 — the difference is audible in the result: the
  /// D above the G string's 4th finger is either "fret 7, G string" (following the
  /// fingering) or "fret 0, D string" (preferring open). Null [fingerString]
  /// always falls back to [stringFor], for notes outside the first-position table.
  static ({String string, int fret}) resolve(
    int midi, {
    String? fingerString,
    bool preferOpenFrets = false,
  }) {
    final letter = preferOpenFrets ? stringFor(midi) : (fingerString ?? stringFor(midi));
    return (string: letter, fret: midi - openMidi[letter]!);
  }
}

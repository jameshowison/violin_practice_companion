import '../models/parsed_piece.dart';

/// Every distinct low/high finger placement the piece asks for — the labels
/// carrying an `L` or `H` suffix (`A2L`, `G3H`), each once, as stored and never
/// rewritten (see the fingering label rule in CLAUDE.md).
///
/// These are the fingerings that leave the hand's basic shape, so they are what
/// a player most needs warning of before starting a tune. Ordered by string,
/// low to high (G D A E), then by finger, so the list reads across the
/// fingerboard.
List<String> nonStandardFingerings(ParsedPiece parsed) {
  final seen = <(String, String)>{};
  for (final n in parsed.allNotes) {
    final string = n.fingerString;
    final finger = n.fingerNumber;
    if (n.isRest || string == null || finger == null) continue;
    if (!finger.endsWith('L') && !finger.endsWith('H')) continue;
    seen.add((string, finger));
  }
  int stringRank(String s) {
    final i = _stringOrder.indexOf(s);
    return i < 0 ? _stringOrder.length : i;
  }

  final sorted = seen.toList()
    ..sort((a, b) {
      final byString = stringRank(a.$1).compareTo(stringRank(b.$1));
      return byString != 0 ? byString : a.$2.compareTo(b.$2);
    });
  return [for (final (s, f) in sorted) '$s$f'];
}

const _stringOrder = ['G', 'D', 'A', 'E'];

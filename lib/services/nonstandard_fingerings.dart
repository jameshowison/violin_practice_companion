import '../models/note_number_mode.dart';
import '../models/parsed_piece.dart';
import 'fingering_annotation_builder.dart';

/// Every distinct low/high finger placement the piece asks for — the notes
/// whose label carries an `L` or `H` suffix (`A2L`, `G3H`), each once.
///
/// These are the fingerings that leave the hand's basic shape, so they are what
/// a player most needs warning of before starting a tune. Ordered by string,
/// low to high (G D A E), then by number, so the list reads across the
/// fingerboard.
///
/// On the violin ([NoteNumberMode.violinFingering]) the labels are as stored and
/// never rewritten (see the fingering label rule in CLAUDE.md). On the mandolin
/// the same notes are named by string and fret instead (`A3`), as [shownNumber]
/// places them under [fretStyle] — a fret has no low or high.
List<String> nonStandardFingerings(
  ParsedPiece parsed, {
  NoteNumberMode numberMode = NoteNumberMode.violinFingering,
  FretStyle fretStyle = FretStyle.openStrings,
}) {
  final seen = <(String, String)>{};
  for (final n in parsed.allNotes) {
    final finger = n.fingerNumber;
    if (n.isRest || n.fingerString == null || finger == null) continue;
    if (!finger.endsWith('L') && !finger.endsWith('H')) continue;
    final shown = shownNumber(n, numberMode, fretStyle);
    seen.add((shown.string ?? '', shown.number));
  }
  int stringRank(String s) {
    final i = _stringOrder.indexOf(s);
    return i < 0 ? _stringOrder.length : i;
  }

  // Numerically where both are plain numbers, so fret 10 follows fret 9.
  int byNumber(String a, String b) {
    final x = int.tryParse(a), y = int.tryParse(b);
    return x != null && y != null ? x.compareTo(y) : a.compareTo(b);
  }

  final sorted = seen.toList()
    ..sort((a, b) {
      final byString = stringRank(a.$1).compareTo(stringRank(b.$1));
      return byString != 0 ? byString : byNumber(a.$2, b.$2);
    });
  return [for (final (s, f) in sorted) '$s$f'];
}

const _stringOrder = ['G', 'D', 'A', 'E'];

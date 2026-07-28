import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Regression for the "Will The Circle Be Unbroken" import lockup: the ABC has
/// a blank line right after `K:` (which abcjs treats as end-of-tune) and blank
/// lines between strains. The converter now strips body blank lines and refuses
/// to emit a music-less score, so the golden `circle.musicxml` must parse to a
/// real, non-empty piece with its chords intact. See `circle.abc`.
void main() {
  final parser = MusicXmlParser();

  test('imported Circle is non-empty (no more empty-piece lockup)', () {
    final piece = parser
        .parse(File('test/fixtures/circle.musicxml').readAsStringSync());
    expect(piece.keyFifths, 2); // D major
    expect(piece.keyMode, KeyMode.major);
    expect(piece.measures, isNotEmpty);
    expect(piece.allNotes.where((n) => !n.isRest), isNotEmpty);
  });

  test('Circle keeps its D and G chord symbols through conversion', () {
    final piece = parser
        .parse(File('test/fixtures/circle.musicxml').readAsStringSync());
    final chords =
        piece.allNotes.map((n) => n.chordSymbol).whereType<String>().toSet();
    expect(chords, containsAll(<String>{'D', 'G'}));
  });
}

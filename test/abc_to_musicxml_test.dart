import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Validates the *downstream contract*: the MusicXML produced by the bundled
/// abcjs-based JS converter must parse cleanly through the app's real
/// [MusicXmlParser]. The golden fixture `test/fixtures/devils_dream.musicxml`
/// was captured by converting `test/fixtures/devils_dream.abc` (The Devil's
/// Dream reel) once with that converter — see the import-from-ABC plan. The
/// live ABC→MusicXML conversion runs JS (dart:js_interop on web, flutter_js on
/// native) and is exercised by on-device verification, not here.
void main() {
  final parser = MusicXmlParser();
  late final ParsedPiece piece;

  setUpAll(() {
    final xml = File('test/fixtures/devils_dream.musicxml').readAsStringSync();
    piece = parser.parse(xml);
  });

  test('parses the converted key signature (A major)', () {
    expect(piece.keyFifths, 3);
    expect(piece.keyMode, KeyMode.major);
    expect(piece.keySignature, 'A');
  });

  test('parses 4/4 time', () {
    expect(piece.beatsPerMeasure, 4);
    expect(piece.beatType, 4);
  });

  test('parses all measures including the anacrusis', () {
    // The converter numbers the pickup as measure 1 and real bars from 2; 17
    // bars plus the pickup = 18 measures.
    expect(piece.measures.length, 18);
  });

  test('first measure is the short e2 pickup and is not flagged as an error',
      () {
    final pickup = piece.measures.first;
    // e2 at L:1/8 == one quarter note.
    expect(pickup.notes.length, 1);
    expect(pickup.notes.first.pitch, 'E5');
    expect(pickup.notes.first.noteValue, NoteValue.quarter);
    expect(pickup.isShort(piece.beatsPerMeasure, piece.beatType), isTrue);
    // The short first measure must never be flagged (it's a pickup, even though
    // it's numbered 1 rather than 0).
    expect(piece.flaggedMeasureNumbers, isNot(contains(pickup.number)));
  });

  test('preserves the |: :| repeats', () {
    expect(piece.measures.any((m) => m.repeatStart), isTrue);
    expect(piece.measures.any((m) => m.repeatEnd), isTrue);
  });

  test('every visible note carries a real pitch or rest (no parse gaps)', () {
    final notes = piece.allNotes;
    expect(notes, isNotEmpty);
    for (final n in notes) {
      expect(n.isRest || n.midiNumber > 0, isTrue,
          reason: 'note ${n.pitch} parsed with no MIDI number');
    }
  });
}

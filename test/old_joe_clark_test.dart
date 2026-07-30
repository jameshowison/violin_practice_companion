import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/chord_analysis.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Old Joe Clark is `K: Amix` — A mixolydian, which carries D major's two
/// sharps but resolves to A. The converter used to collapse every modal key to
/// major, so the app read the piece as D major and labelled the opening A chord
/// V instead of I.
///
/// Golden fixture, captured from `test/fixtures/old_joe_clark.abc` with the
/// bundled abcjs converter (same approach as `abc_to_musicxml_test.dart` — the
/// live conversion runs JS and is verified on-device).
void main() {
  final parser = MusicXmlParser();
  late final ParsedPiece piece;

  setUpAll(() {
    piece = parser
        .parse(File('test/fixtures/old_joe_clark.musicxml').readAsStringSync());
  });

  test('the mixolydian mode survives the conversion', () {
    expect(piece.keyFifths, 2, reason: 'A mixolydian shares D major\'s signature');
    expect(piece.keyMode, KeyMode.mixolydian);
    expect(piece.keySignature, 'Amix');
  });

  test('the tune\'s chord symbols are preserved', () {
    final symbols = piece.allNotes
        .map((n) => n.chordSymbol)
        .whereType<String>()
        .toSet();
    expect(symbols, {'A', 'E', 'G'});
  });

  test('the opening A chord analyzes as I, not V', () {
    final first = piece.allNotes.firstWhere((n) => n.chordSymbol != null);
    expect(first.chordSymbol, 'A');
    expect(
      ChordAnalysis.romanNumeral(
          keyFifths: piece.keyFifths,
          keyMode: piece.keyMode,
          chordName: first.chordSymbol!),
      'I',
    );
  });

  test('the tune reads I / V / ♭VII', () {
    String? deg(String c) => ChordAnalysis.romanNumeral(
        keyFifths: piece.keyFifths, keyMode: piece.keyMode, chordName: c);
    expect(deg('A'), 'I');
    expect(deg('E'), 'V');
    expect(deg('G'), '♭VII');
  });

  test('keyName round-trips every mode, and major/minor are unchanged', () {
    // The signature's relative major is what jianpu numbers 1 from, so a modal
    // piece must still resolve to it.
    expect(MusicXmlParser.keyName(2, KeyMode.major), 'D');
    expect(MusicXmlParser.keyName(2, KeyMode.mixolydian), 'Amix');
    expect(MusicXmlParser.keyName(2, KeyMode.minor), 'Bm');
    expect(MusicXmlParser.keyName(0, KeyMode.dorian), 'Ddor');
    expect(MusicXmlParser.keyName(0, KeyMode.phrygian), 'Ephr');
    expect(MusicXmlParser.keyName(0, KeyMode.lydian), 'Flyd');
    expect(MusicXmlParser.keyName(0, KeyMode.locrian), 'Bloc');
    // Pre-existing names must not drift.
    expect(MusicXmlParser.keyName(0, KeyMode.major), 'C');
    expect(MusicXmlParser.keyName(3, KeyMode.minor), 'F#m');
    expect(MusicXmlParser.keyName(-2, KeyMode.major), 'Bb');
  });

  test('parseKeyMode accepts every MusicXML mode name', () {
    expect(MusicXmlParser.parseKeyMode('mixolydian'), KeyMode.mixolydian);
    expect(MusicXmlParser.parseKeyMode('Dorian'), KeyMode.dorian);
    expect(MusicXmlParser.parseKeyMode('aeolian'), KeyMode.minor);
    expect(MusicXmlParser.parseKeyMode('minor'), KeyMode.minor);
    expect(MusicXmlParser.parseKeyMode(null), KeyMode.major);
    expect(MusicXmlParser.parseKeyMode('ionian'), KeyMode.major);
  });

  test('the piece parses into measures with notes', () {
    expect(piece.measures, isNotEmpty);
    expect(piece.allNotes.where((n) => !n.isRest), isNotEmpty);
  });
}

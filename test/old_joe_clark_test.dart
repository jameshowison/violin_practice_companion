import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/chord_analysis.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
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
    piece = parser.parse(MusicXmlNormalizer.toSoundingPitch(
        File('test/fixtures/old_joe_clark.musicxml').readAsStringSync()));
  });

  test('the mixolydian mode survives the conversion', () {
    expect(piece.keyFifths, 2, reason: 'A mixolydian shares D major\'s signature');
    expect(piece.keyMode, KeyMode.mixolydian);
    expect(piece.keySignature, 'Amix');
  });

  test('the two sharps sound, and the flat seventh stays flat', () {
    // Mixolydian is the case that makes this worth stating: the signature
    // sharpens F and C, and the G — the ♭7 that makes the mode — must NOT be
    // sharpened along with them. Before the normalizer every one of these
    // played natural, so the tune came out in A minor-ish.
    Set<int> pitchClasses(String step) => piece.allNotes
        .where((n) => !n.isRest && n.pitch.startsWith(step))
        .map((n) => n.midiNumber % 12)
        .toSet();
    expect(pitchClasses('F'), {6}, reason: 'F#');
    expect(pitchClasses('C'), {1}, reason: 'C#');
    expect(pitchClasses('G'), {7}, reason: 'G natural — the mixolydian ♭7');
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

  test('the repeat pickups are not flagged as duration errors', () {
    // |: A2 | … | A6 :| twice: measures 1/10 are 1-beat pickups and 9/18 are
    // 3-beat bars that run back into them. All four are short on paper; none is
    // a mistake.
    final short = piece.measures
        .where((m) => m.isShort(piece.beatsPerMeasure, piece.beatType))
        .map((m) => m.number)
        .toList();
    expect(short, [1, 9, 10, 18], reason: 'the four half-bars of the two strains');
    expect(piece.flaggedMeasureNumbers, isEmpty);
  });

  test('the piece parses into measures with notes', () {
    expect(piece.measures, isNotEmpty);
    expect(piece.allNotes.where((n) => !n.isRest), isNotEmpty);
  });
}

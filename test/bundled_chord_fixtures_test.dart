import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/services/chord_analysis.dart';
import 'package:violin_practice_companion/services/chord_shape_library.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// The two tunes seeded from `docs/wellerman.abc`.
///
/// Old Joe Clark is the only bundled fixture carrying `<harmony>`, so it is the
/// only piece a fresh install has that exercises the chord lane and the "New
/// chords" diagrams — worth pinning as shipped, not merely as converter output.
/// `old_joe_clark_test.dart` covers the conversion; this covers the asset that
/// conversion produced. The Wellerman is chordless, and is here for its key.
///
/// The mode is the thing most likely to rot. A `<mode>` that goes missing does
/// not change a single engraved glyph — A mixolydian and D major spell the same
/// two sharps — so the only symptom is the roman numerals quietly re-reading
/// the tonic as V. That is precisely the bug this pair was added to demonstrate.
void main() {
  final parser = MusicXmlParser();

  ({int fifths, KeyMode mode, String name, Set<String> chords}) read(String f) {
    final p = parser.parse(File('assets/fixtures/$f.xml').readAsStringSync());
    return (
      fifths: p.keyFifths,
      mode: p.keyMode,
      name: p.keySignature,
      chords: p.allNotes.map((n) => n.chordSymbol).whereType<String>().toSet(),
    );
  }

  List<Section> sections(String f) =>
      ((json.decode(File('assets/fixtures/sections/${f}_sections.json')
                  .readAsStringSync()) as Map<String, dynamic>)['sections']
              as List)
          .cast<Map<String, dynamic>>()
          .map(Section.fromJson)
          .toList();

  group('Old Joe Clark', () {
    test('ships as A mixolydian, not D major', () {
      final p = read('old_joe_clark');
      expect(p.fifths, 2);
      expect(p.mode, KeyMode.mixolydian,
          reason: 'losing this re-reads the tonic A as V of D');
      expect(p.name, 'Amix');
    });

    test('its chords read I / V / ♭VII', () {
      final p = read('old_joe_clark');
      expect(p.chords, {'A', 'E', 'G'});
      String? deg(String c) => ChordAnalysis.romanNumeral(
          keyFifths: p.fifths, keyMode: p.mode, chordName: c);
      expect(deg('A'), 'I');
      expect(deg('E'), 'V');
      expect(deg('G'), '♭VII');
    });

    test('every chord it uses has a diagram to draw', () {
      // Without this the tune ships with a chord lane and an empty footer —
      // and on a phone, a tray that declines to open at all.
      for (final c in read('old_joe_clark').chords) {
        expect(ChordShapeLibrary.lookup(c), isNotNull, reason: 'no shape for $c');
      }
    });
  });

  group('The Wellerman', () {
    test('ships as E minor', () {
      final p = read('the_wellerman');
      expect(p.fifths, 1);
      expect(p.mode, KeyMode.minor);
      expect(p.name, 'Em');
    });
  });

  test('both ship with an A/B section split at bar 10', () {
    for (final f in ['old_joe_clark', 'the_wellerman']) {
      final s = sections(f);
      expect(s.map((e) => e.label).toList(), ['A', 'B'], reason: f);
      expect(s.map((e) => e.startMeasure).toList(), [1, 10], reason: f);
    }
  });
}

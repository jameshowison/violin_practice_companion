import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Wraps [measures] (raw `<measure>` elements) in the minimum score around them.
/// Mirrors the helper in `abc_exporter_test.dart`.
String _score(String measures, {int fifths = 0}) => '''
<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">$measures</part>
</score-partwise>'''
    .replaceFirst('<measure number="1">', '''<measure number="1">
      <attributes>
        <divisions>4</divisions>
        <key><fifths>$fifths</fifths><mode>major</mode></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>''');

String _note(String step, int octave, {int? alter, String? accidental}) =>
    '<note><pitch><step>$step</step>'
    '${alter == null ? '' : '<alter>$alter</alter>'}'
    '<octave>$octave</octave></pitch><duration>4</duration><type>quarter</type>'
    '${accidental == null ? '' : '<accidental>$accidental</accidental>'}</note>';

/// The MIDI numbers the app would actually play, in order — the whole point of
/// normalizing, since everything downstream of the staff reads `midiNumber`.
List<int> _sounding(String xml) => MusicXmlParser()
    .parse(MusicXmlNormalizer.toSoundingPitch(xml))
    .allNotes
    .where((n) => !n.isRest)
    .map((n) => n.midiNumber)
    .toList();

void main() {
  group('a drawing-led file gains its key signature', () {
    test('an unmarked F under one sharp sounds F#', () {
      final xml = _score(
          '<measure number="1">${_note('F', 4)}${_note('G', 4)}</measure>',
          fifths: 1);
      expect(_sounding(xml), [66, 67]); // F#4, G4 — not 65
    });

    test('one flat lowers the B and leaves the rest alone', () {
      final xml = _score(
          '<measure number="1">${_note('B', 4)}${_note('E', 4)}</measure>',
          fifths: -1);
      expect(_sounding(xml), [70, 64]); // Bb4, E4
    });

    test('the staff is untouched — no accidental is invented', () {
      final xml = _score('<measure number="1">${_note('F', 4)}</measure>',
          fifths: 1);
      final out = MusicXmlNormalizer.toSoundingPitch(xml);
      expect(out, contains('<alter>1</alter>'));
      expect(out, isNot(contains('<accidental>')));
      // The parser's view of what is *drawn* is unchanged, so Verovio engraves
      // exactly what it engraved before: a bare F on the top line.
      expect(MusicXmlParser().parse(out).allNotes.first.displayAccidental,
          isNull);
    });
  });

  group('drawn accidentals hold for the rest of their bar', () {
    test('a natural clears the signature and carries to the next F', () {
      final xml = _score(
          '<measure number="1">'
          '${_note('F', 4, accidental: 'natural')}${_note('F', 4)}'
          '</measure>',
          fifths: 1);
      expect(_sounding(xml), [65, 65]); // both F natural
    });

    test('but not past the barline', () {
      final xml = _score(
          '<measure number="1">${_note('F', 4, accidental: 'natural')}</measure>'
          '<measure number="2">${_note('F', 4)}</measure>',
          fifths: 1);
      expect(_sounding(xml), [65, 66]); // F natural, then the signature's F#
    });

    test('and not into another octave', () {
      // A natural on F4 says nothing about F5; the signature still governs it.
      final xml = _score(
          '<measure number="1">'
          '${_note('F', 4, accidental: 'natural')}${_note('F', 5)}'
          '</measure>',
          fifths: 1);
      expect(_sounding(xml), [65, 78]); // F4 natural, F#5
    });

    test('a drawn sharp in a signature-free key carries too', () {
      final xml = _score('<measure number="1">'
          '${_note('C', 4, alter: 1, accidental: 'sharp')}${_note('C', 4)}'
          '</measure>');
      expect(_sounding(xml), [61, 61]);
    });

    test('a double sharp is not flattened to one semitone', () {
      final xml = _score('<measure number="1">'
          '${_note('F', 4, alter: 2, accidental: 'double-sharp')}'
          '</measure>');
      expect(_sounding(xml), [67]);
    });
  });

  test('an explicit undrawn alteration is real data and survives', () {
    // A flat in a sharp key with no sign drawn: the file means it, so the key
    // signature must not overwrite it. (This note is also the fingerprint that
    // makes the whole file read as sounding-led — see the next group.)
    final xml = _score(
        '<measure number="1">${_note('B', 4, alter: -1)}</measure>',
        fifths: 1);
    expect(_sounding(xml), [70]);
  });

  group('a sounding-led file is left completely alone', () {
    test('one undrawn alteration is enough to gate the whole document', () {
      // Both F's are bare, but the C# states itself without an accidental —
      // the file says what it means, so the F's really are naturals.
      final xml = _score(
          '<measure number="1">'
          '${_note('F', 4)}${_note('C', 5, alter: 1)}'
          '</measure>',
          fifths: 1);
      expect(MusicXmlNormalizer.toSoundingPitch(xml), xml);
      expect(_sounding(xml), [65, 73]);
    });

    test('a redundant drawn sharp does NOT make a drawing-led file look led', () {
      // The Devil's Dream writes `BA^GB` in A major — a sharp on a note the
      // signature already sharpens. The bare F must still come out F#.
      final xml = _score(
          '<measure number="1">'
          '${_note('F', 4)}${_note('G', 4, alter: 1, accidental: 'sharp')}'
          '</measure>',
          fifths: 3);
      expect(_sounding(xml), [66, 68]);
    });

    test('every bundled fixture comes back byte-identical', () {
      // MuseScore and the OMR engine both state the sounding pitch already;
      // normalizing must never second-guess them.
      final fixtures = Directory('assets/fixtures')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.xml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      expect(fixtures, isNotEmpty);
      for (final f in fixtures) {
        final xml = f.readAsStringSync();
        expect(MusicXmlNormalizer.toSoundingPitch(xml), xml, reason: f.path);
      }
    });
  });

  test('normalizing twice is the same as normalizing once', () {
    final xml = _score(
        '<measure number="1">'
        '${_note('F', 4)}${_note('C', 5, accidental: 'natural')}'
        '</measure>'
        '<measure number="2">${_note('C', 5)}${_note('F', 5)}</measure>',
        fifths: 2);
    final once = MusicXmlNormalizer.toSoundingPitch(xml);
    expect(MusicXmlNormalizer.toSoundingPitch(once), once);
  });

  test('rests and malformed input pass through without throwing', () {
    final withRest = _score(
        '<measure number="1">'
        '<note><rest/><duration>4</duration><type>quarter</type></note>'
        '${_note('F', 4)}</measure>',
        fifths: 1);
    expect(_sounding(withRest), [66]);
    expect(MusicXmlNormalizer.toSoundingPitch('not xml at all'), 'not xml at all');
  });
}

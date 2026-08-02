import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/abc_exporter.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Header + body of one exported document, split so tests can assert on the
/// tune without the `X:`/`T:`/`M:`/`L:`/`K:` block getting in the way.
({List<String> headers, List<String> body}) _split(String abc) {
  final lines = abc.trim().split('\n');
  final headerEnd = lines.indexWhere((l) => l.startsWith('K:'));
  return (
    headers: lines.sublist(0, headerEnd + 1),
    body: lines.sublist(headerEnd + 1),
  );
}

String _export(String xml, {String title = 'Test Tune'}) =>
    AbcExporter.export(MusicXmlParser().parse(xml), title: title);

/// Wraps [measures] (raw `<measure>` elements) in the minimum score around them.
String _score(String measures, {int fifths = 0, String mode = 'major'}) => '''
<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">$measures</part>
</score-partwise>'''
    .replaceFirst('<part id="P1">', '''<part id="P1">
      <!-- attributes go inside the first measure -->''')
    .replaceFirst('<!-- attributes go inside the first measure -->', '')
    .replaceFirst('<measure number="1">', '''<measure number="1">
      <attributes>
        <divisions>4</divisions>
        <key><fifths>$fifths</fifths><mode>$mode</mode></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>''');

String _note(String step, int octave,
        {String type = 'quarter',
        int? alter,
        bool dot = false,
        bool chord = false}) =>
    '<note>${chord ? '<chord/>' : ''}<pitch><step>$step</step>'
    '${alter == null ? '' : '<alter>$alter</alter>'}'
    '<octave>$octave</octave></pitch><duration>4</duration>'
    '<type>$type</type>${dot ? '<dot/>' : ''}</note>';

void main() {
  group('headers', () {
    test('carry the title, meter, unit length and key', () {
      final abc = _export(
        _score('<measure number="1">${_note('D', 4)}</measure>', fifths: 2),
        title: 'Lightly Row',
      );
      expect(_split(abc).headers, [
        'X: 1',
        'T: Lightly Row',
        'M: 4/4',
        // Only quarter notes, so the unit is capped at an eighth rather than
        // printing everything as a bare quarter.
        'L: 1/8',
        'K: D',
      ]);
    });

    test('name the mode, not just the signature', () {
      final abc = _export(
        _score('<measure number="1">${_note('A', 4)}</measure>',
            fifths: 2, mode: 'mixolydian'),
      );
      expect(_split(abc).headers, contains('K: Amix'));
    });

    test('flatten a multi-line title so it cannot break the header block', () {
      final abc = _export(
        _score('<measure number="1">${_note('C', 4)}</measure>'),
        title: 'Minuet\nNo. 2 ',
      );
      expect(_split(abc).headers[1], 'T: Minuet No. 2');
    });

    test('drop the unit length to 1/16 when the tune has sixteenths', () {
      final abc = _export(_score('<measure number="1">'
          '${_note('C', 4, type: '16th')}${_note('D', 4, type: 'eighth')}'
          '</measure>'));
      expect(_split(abc).headers, contains('L: 1/16'));
      // C is one unit (bare), D is two; both fall in the first beat, so they
      // are beamed together rather than spaced apart.
      expect(_split(abc).body.first, startsWith('CD2'));
    });
  });

  group('pitches', () {
    test('use ABC octave conventions around middle C', () {
      final abc = _export(_score('<measure number="1">'
          '${_note('C', 3)}${_note('C', 4)}${_note('C', 5)}${_note('C', 6)}'
          '${_note('C', 2)}'
          '</measure>'));
      expect(_split(abc).body.first, startsWith("C,2 C2 c2 c'2 C,,2"));
    });

    test('leave key-signature accidentals implicit', () {
      // F# and C# are in the signature of D major; the G is not altered.
      final abc = _export(
        _score('<measure number="1">'
            '${_note('F', 4, alter: 1)}${_note('C', 5, alter: 1)}'
            '${_note('G', 4)}'
            '</measure>',
            fifths: 2),
      );
      expect(_split(abc).body.first, startsWith('F2 c2 G2'));
    });

    test('spell out accidentals that depart from the signature', () {
      final abc = _export(
        _score('<measure number="1">'
            '${_note('C', 4, alter: 1)}${_note('B', 4, alter: -1)}'
            '${_note('F', 4, alter: 2)}'
            '</measure>'),
      );
      expect(_split(abc).body.first, startsWith('^C2 _B2 ^^F2'));
    });

    test('restate a letter for the rest of the bar once it is altered', () {
      // The second F is natural per the (empty) signature, but a reader that
      // carries the ^ across octaves would sharpen it — so it is written out.
      final abc = _export(
        _score('<measure number="1">'
            '${_note('F', 4, alter: 1)}${_note('F', 5)}${_note('G', 4)}'
            '</measure>'
            '<measure number="2">${_note('F', 4)}</measure>'),
      );
      final body = _split(abc).body.first;
      expect(body, startsWith('^F2 =f2 G2'));
      // A new bar clears the state: plain F again.
      expect(body, contains('| F2'));
    });
  });

  group('two <alter> conventions', () {
    // Same three notes both ways: an F under a two-sharp signature, plus one
    // note that pins down which convention the file follows.
    String tune(String extra) => _score(
        '<measure number="1">${_note('F', 4)}$extra</measure>',
        fifths: 2);

    test('a file that never alters a note silently is drawing-led', () {
      // The only <alter> comes with a drawn accidental — the fingerprint of the
      // bundled ABC converter's output, where key-signature sharps are implicit.
      // So the bare F is the signature's F#, not an F natural.
      final abc = _export(tune(
          '<note><pitch><step>G</step><alter>1</alter><octave>4</octave></pitch>'
          '<duration>4</duration><type>quarter</type>'
          '<accidental>sharp</accidental></note>'));
      expect(_split(abc).body.first, startsWith('F2 ^G2'));
    });

    test('an alter with no accidental beside it means sounding pitch', () {
      // MuseScore and the OMR output state every alteration, drawn or not, so
      // here the bare F really is an F natural and has to say so.
      final abc = _export(tune(
          '<note><pitch><step>C</step><alter>1</alter><octave>5</octave></pitch>'
          '<duration>4</duration><type>quarter</type></note>'));
      expect(_split(abc).body.first, startsWith('=F2 c2'));
    });
  });

  group('rhythm', () {
    test('writes lengths as multiples of the unit, dots included', () {
      final abc = _export(_score('<measure number="1">'
          '${_note('C', 4, type: 'eighth')}${_note('D', 4)}'
          '${_note('E', 4, type: 'half')}${_note('F', 4, type: 'whole')}'
          '</measure>'
          '<measure number="2">${_note('G', 4, type: 'half', dot: true)}'
          '</measure>'));
      expect(_split(abc).body.first, startsWith('CD2 E4 F8 | G6'));
    });

    test('picks a unit that keeps an odd value whole', () {
      // A dotted sixteenth is 3/32 of a bar, which no power-of-two unit longer
      // than 1/32 divides — so the unit drops rather than the length becoming a
      // fraction.
      final abc = _export(_score('<measure number="1">'
          '${_note('C', 4, type: '16th', dot: true)}'
          '${_note('D', 4, type: 'eighth')}'
          '</measure>'));
      expect(_split(abc).headers, contains('L: 1/32'));
      expect(_split(abc).body.first, startsWith('C3D4'));
    });

    test('beams eighths per beat in 4/4', () {
      final eighths =
          List.filled(8, _note('A', 4, type: 'eighth')).join();
      final abc = _export(_score('<measure number="1">$eighths</measure>'));
      expect(_split(abc).body.first, startsWith('AA AA AA AA'));
    });

    test('beams 6/8 in dotted beats, not in six', () {
      final eighths =
          List.filled(6, _note('A', 4, type: 'eighth')).join();
      final abc = _export(_score('<measure number="1">$eighths</measure>')
          .replaceFirst('<beats>4</beats><beat-type>4</beat-type>',
              '<beats>6</beats><beat-type>8</beat-type>'));
      expect(_split(abc).headers, contains('M: 6/8'));
      expect(_split(abc).body.first, startsWith('AAA AAA'));
    });

    test('writes rests as z', () {
      final abc = _export(_score('<measure number="1">'
          '<note><rest/><duration>4</duration><type>half</type></note>'
          '${_note('A', 4)}</measure>'));
      expect(_split(abc).body.first, startsWith('z4 A2'));
    });
  });

  group('chords', () {
    test('stack <chord/> notes into one bracketed ABC chord', () {
      final abc = _export(_score('<measure number="1">'
          '${_note('C', 4, type: 'half')}'
          '${_note('E', 4, type: 'half', chord: true)}'
          '${_note('G', 4, type: 'half', chord: true)}'
          '${_note('A', 4, type: 'half')}'
          '</measure>'));
      expect(_split(abc).body.first, startsWith('[CEG]4 A4'));
    });

    test('put chord symbols in quotes ahead of their note', () {
      final abc = _export(_score('''<measure number="1">
          <harmony><root><root-step>A</root-step></root><kind>minor</kind></harmony>
          ${_note('A', 4)}
          <harmony><root><root-step>E</root-step></root><kind>dominant</kind></harmony>
          ${_note('E', 5)}
        </measure>'''));
      expect(_split(abc).body.first, startsWith('"Am"A2 "E7"e2'));
    });
  });

  group('barlines', () {
    String repeats({bool start = false, bool end = false}) =>
        '${start ? '<barline location="left"><repeat direction="forward"/></barline>' : ''}'
        '${end ? '<barline location="right"><repeat direction="backward"/></barline>' : ''}';

    test('close a tune without repeats on a final barline', () {
      final abc = _export(_score(
          '<measure number="1">${_note('C', 4, type: 'whole')}</measure>'
          '<measure number="2">${_note('D', 4, type: 'whole')}</measure>'));
      expect(_split(abc).body.first, 'C8 | D8 |]');
    });

    test('open and close a repeated strain', () {
      final abc = _export(_score(
          '<measure number="1">${repeats(start: true)}'
          '${_note('C', 4, type: 'whole')}</measure>'
          '<measure number="2">${_note('D', 4, type: 'whole')}'
          '${repeats(end: true)}</measure>'));
      expect(_split(abc).body.first, '|: C8 | D8 :|');
    });

    test('split :: across a line break back into :| and |:', () {
      final measures = [
        for (var i = 1; i <= 5; i++)
          '<measure number="$i">'
          '${i == 5 ? repeats(start: true) : ''}'
          '${_note('C', 4, type: 'whole')}'
          '${i == 4 ? repeats(end: true) : ''}</measure>'
      ].join();
      final body = _split(_export(_score(measures))).body;
      expect(body[0], endsWith('C8 :|'));
      expect(body[1], startsWith('|: C8'));
    });

    test('collapse a back-to-back close and open into ::', () {
      final abc = _export(_score(
          '<measure number="1">${_note('C', 4, type: 'whole')}'
          '${repeats(end: true)}</measure>'
          '<measure number="2">${repeats(start: true)}'
          '${_note('D', 4, type: 'whole')}${repeats(end: true)}</measure>'));
      expect(_split(abc).body.first, 'C8 :: D8 :|');
    });

    test('wrap onto a new line every four bars', () {
      final measures = [
        for (var i = 1; i <= 5; i++)
          '<measure number="$i">${_note('C', 4, type: 'whole')}</measure>'
      ].join();
      final body = _split(_export(_score(measures))).body;
      expect(body.length, 2);
      // The barline that closes the fourth bar stays with it, rather than
      // leading the next line where it would read as the wrong bar's.
      expect(body[0], 'C8 | C8 | C8 | C8 |');
      expect(body[1], 'C8 |]');
    });
  });

  group('Old Joe Clark round trip', () {
    late final String abc;

    setUpAll(() {
      final xml = File('test/fixtures/old_joe_clark.musicxml').readAsStringSync();
      abc = AbcExporter.export(MusicXmlParser().parse(xml),
          title: 'Old Joe Clark');
    });

    test('recovers the mixolydian key and 4/4 meter', () {
      expect(_split(abc).headers, containsAll(['M: 4/4', 'L: 1/8', 'K: Amix']));
    });

    test('keeps the chord symbols the tune was imported with', () {
      for (final symbol in ['"A"', '"E"', '"G"']) {
        expect(abc, contains(symbol));
      }
    });

    test('keeps both repeated strains', () {
      // The tune is two repeated strains back to back, so the join between them
      // is the single `::` — and the second `:|` is the last thing in the tune.
      final body = _split(abc).body.join(' ');
      expect(body, startsWith('|: '));
      expect('::'.allMatches(body), hasLength(1));
      expect(body.trimRight(), endsWith(':|'));
    });
  });
}

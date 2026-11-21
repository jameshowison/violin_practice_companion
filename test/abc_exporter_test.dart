import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';

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
        String? accidental,
        bool dot = false,
        bool chord = false}) =>
    '<note>${chord ? '<chord/>' : ''}<pitch><step>$step</step>'
    '${alter == null ? '' : '<alter>$alter</alter>'}'
    '<octave>$octave</octave></pitch><duration>4</duration>'
    '<type>$type</type>${dot ? '<dot/>' : ''}'
    '${accidental == null ? '' : '<accidental>$accidental</accidental>'}</note>';

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
        title: 'Sonatina\nOp. 36 ',
      );
      expect(_split(abc).headers[1], 'T: Sonatina Op. 36');
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

  group('sounding pitch is the only convention the exporter reads', () {
    test('a bare <step> with no <alter> is a natural, whatever the key says', () {
      // The exporter takes <alter> at its word: an F with none is an F natural
      // even under two sharps, and has to be written out as `=F`. Files that
      // leave key-signature sharps implicit — everything the bundled ABC
      // converter produces — are resolved by MusicXmlNormalizer on the way in,
      // so they never reach here. See `musicxml_normalizer_test.dart`.
      final abc = _export(_score(
          '<measure number="1">${_note('F', 4)}${_note('C', 5, alter: 1)}'
          '</measure>',
          fifths: 2));
      expect(_split(abc).body.first, startsWith('=F2 c2'));
    });

    test('an ABC-converted tune survives the round trip', () {
      // The whole path a tune actually takes: drawing-led MusicXML (a bare F
      // under one sharp, as the converter writes it) → normalizer → parser →
      // exporter. The F# must come back out implicit, exactly as it went in.
      final drawingLed = _score(
          '<measure number="1">${_note('E', 4)}${_note('F', 4)}'
          '${_note('G', 4)}${_note('F', 4, accidental: 'natural')}</measure>',
          fifths: 1);
      final abc = _export(MusicXmlNormalizer.toSoundingPitch(drawingLed));
      expect(_split(abc).headers, contains('K: G'));
      expect(_split(abc).body.first, startsWith('E2 F2 G2 =F2'));
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
  group('navigation marks', () {
    String exportFixture(String name) => AbcExporter.export(
        MusicXmlParser()
            .parse(File('test/fixtures/$name.musicxml').readAsStringSync()),
        title: name);

    // Written where abcjs reads them back onto the same bars — checked by
    // converting this output with scripts/abc_to_musicxml.cjs.
    // A Fine before a wrapped `|:` still gets its own barline: abcjs drops a
    // mark left dangling at a line end.
    test('Fine and D.C. al Fine close their bars', () {
      final body = _split(exportFixture('dc_al_fine')).body.join(' ');
      expect(body, contains('g8 !fine! |'));
      expect(body, contains('G4 !D.C.alfine! |]'));
    });

    test('segno, To Coda and coda open their bars; D.S. al Coda closes one', () {
      final body = _split(exportFixture('ds_al_coda')).body.join(' ');
      expect(body, contains('| !segno! d2'));
      expect(body, contains('| "^To Coda" a2'));
      expect(body, contains('G4 !D.S.alcoda! |'));
      expect(body, contains('!coda! G2'));
    });
  });

  group('endings', () {
    test("Devil's Dream keeps its |1 and :|2 endings on the way out", () {
      final xml = MusicXmlNormalizer.toSoundingPitch(
          File('test/fixtures/devils_dream.musicxml').readAsStringSync());
      final body = _split(_export(xml)).body.join(' ');
      expect(body, contains('[1 '));
      expect(body, contains(':| [2 '));
      expect(RegExp(r'\[1 ').allMatches(body).length, 1);
    });

    test('a second ending followed by more music is closed with ||', () {
      final abc = _export(_score('''
<measure number="1">${_note('C', 4, type: 'whole')}</measure>
<measure number="2"><barline location="left"><ending number="1" type="start"/></barline>${_note('D', 4, type: 'whole')}<barline location="right"><bar-style>light-heavy</bar-style><ending number="1" type="stop"/><repeat direction="backward"/></barline></measure>
<measure number="3"><barline location="left"><ending number="2" type="start"/></barline>${_note('E', 4, type: 'whole')}<barline location="right"><ending number="2" type="discontinue"/></barline></measure>
<measure number="4">${_note('F', 4, type: 'whole')}</measure>'''));
      final body = _split(abc).body.join(' ');
      expect(body, contains('[1 D8 :| [2 E8 || F8'));
    });
  });

  group('key changes', () {
    // G major; D major from bar 3 (mid-line); F major from bar 5, which
    // opens the second line at the default four bars per line.
    String bar(int n, String notes, {int? fifths}) =>
        '<measure number="$n">'
        '${fifths == null ? '' : '<attributes><key><fifths>$fifths</fifths></key></attributes>'}'
        '$notes</measure>';
    final c = _note('C', 5); // C♮ under G
    final cSharp = _note('C', 5, alter: 1); // C♯ from the D key: no sign
    final cNat = _note('C', 5, accidental: 'natural'); // a written ♮ in D
    final bFlat = _note('B', 4, alter: -1); // B♭ from the F key
    final xml = _score([
      bar(1, c * 4),
      bar(2, c * 4),
      bar(3, cSharp + cNat + cSharp + cSharp, fifths: 2),
      bar(4, cSharp * 4),
      bar(5, bFlat * 4, fifths: -1),
    ].join(), fifths: 1);

    test('the header states the opening key', () {
      expect(_split(_export(xml)).headers.last, 'K: G');
    });

    test('a change inside a line is an inline field after the barline', () {
      final body = _split(_export(xml)).body;
      // A plain c is now C♯. After the written ♮ the exporter states every
      // later C in the bar outright (its per-letter rule), so `^c`.
      expect(body.first, contains('| [K:D] c2 =c2 ^c2 ^c2 | c2 c2 c2 c2 |'));
      // Before the change a plain c is C♮, as G says.
      expect(body.first, startsWith('c2 c2 c2 c2 | c2 c2 c2 c2 |'));
    });

    test('a change at the head of a line is a K: line of its own', () {
      final body = _split(_export(xml)).body;
      final at = body.indexOf('K: F');
      expect(at, greaterThan(0));
      expect(body[at + 1], startsWith('B2 B2 B2 B2'),
          reason: 'B♭ is the F key\'s, so it needs no sign');
      expect(body.any((l) => l.contains('[K:F]')), isFalse);
    });

    test('a minor tune names its changes in minor', () {
      final minor = _score([
        bar(1, _note('A', 4) * 4),
        bar(2, _note('B', 4) * 4, fifths: 2),
      ].join(), mode: 'minor');
      final abc = _export(minor);
      expect(_split(abc).headers.last, 'K: Am');
      expect(abc, contains('[K:Bm]'));
    });

    test('a tie into the new key restates the old pitch', () {
      final tied = _score([
        bar(1, _note('A', 4) * 3 +
            _note('C', 5).replaceFirst('</duration>', '</duration><tie type="start"/>')),
        bar(2, _note('C', 5).replaceFirst('</duration>', '</duration><tie type="stop"/>') +
            _note('C', 5, alter: 1) * 3, fifths: 2),
      ].join());
      expect(_split(_export(tied)).body.join(' '),
          contains('| [K:D] =c2 ^c2 ^c2 ^c2 |'));
    });
  });

  // test/fixtures/key_change.musicxml is test/fixtures/key_change.abc through
  // the app's own converter (scripts/abc_to_musicxml.cjs): a `[K:D]` inside
  // a line and a `K:F` line, with plain letters read in the new key.
  group('key change round trip', () {
    final parsed = MusicXmlParser().parse(MusicXmlNormalizer.toSoundingPitch(
        File('test/fixtures/key_change.musicxml').readAsStringSync()));

    test('imports each change at its bar, in sounding pitch', () {
      expect([for (final m in parsed.measures) m.keyChange],
          [1, null, 2, null, -1, null]);
      expect([for (final m in parsed.measures) m.notes.map((n) => n.pitch).join(' ')], [
        'C5 C5 C5 C5', // G: a plain c is C♮
        'C5 C5 C5 C5',
        'C#5 C5 C5 C5', // [K:D]: c is C♯; =c holds to the barline
        'C#5 C#5 C#5 C#5',
        'Bb4 Bb4 Bb4 Bb4', // K:F
        'Bb4',
      ]);
    });

    test('exports the changes back where they were', () {
      final abc = AbcExporter.export(parsed, title: 'Key Change Exercise');
      expect(_split(abc).headers.last, 'K: G');
      final body = _split(abc).body;
      expect(body.first, contains('| [K:D] c2 =c2 =c2 =c2 | c2 c2 c2 c2'));
      expect(body, contains('K: F'));
      expect(body.last, startsWith('B2 B2 B2 B2 | B8'));
    });
  });

  // test/fixtures/meter_change.musicxml is test/fixtures/meter_change.abc
  // through the app's own converter: an inline `[M:3/4]`, an `M:6/8` line
  // (which abcjs reports only as the next line's meter, never as an
  // element), `M:C`, and a key and meter change on the same bar.
  group('meter change round trip', () {
    final parsed = MusicXmlParser().parse(MusicXmlNormalizer.toSoundingPitch(
        File('test/fixtures/meter_change.musicxml').readAsStringSync()));

    test('imports each change at its bar', () {
      expect([for (final m in parsed.measures) m.timeChange?.toString()],
          ['4/4', '3/4', null, '6/8', null, '4/4', '2/4', null]);
      expect(parsed.measures[6].keyChange, 2);
    });

    test('every bar adds up under its own meter', () {
      expect(parsed.flaggedMeasureNumbers, isEmpty);
    });

    test('exports the changes back where they were', () {
      final abc = AbcExporter.export(parsed, title: 'Meter Change Exercise');
      expect(_split(abc).headers, contains('M: 4/4'));
      final body = _split(abc).body.join(' ');
      for (final field in ['[M:3/4]', '[M:6/8]', '[M:4/4]', '[K:D] [M:2/4]']) {
        expect(body, contains(field));
      }
    });
  });
}

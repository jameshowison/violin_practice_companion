// D.C. / D.S. / Fine / Coda in the performance order — what MIDI playback,
// the minimap and the audio aligner all follow.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

Measure _m(
  int number, {
  bool repeatStart = false,
  bool repeatEnd = false,
  bool daCapo = false,
  bool dalSegno = false,
  bool fine = false,
  bool toCoda = false,
  bool segno = false,
  bool coda = false,
}) =>
    Measure(
      number: number,
      notes: const [
        NoteEvent(
            pitch: 'A4',
            midiNumber: 69,
            octave: 4,
            noteValue: NoteValue.whole,
            dotted: false,
            isRest: false),
      ],
      repeatStart: repeatStart,
      repeatEnd: repeatEnd,
      daCapo: daCapo,
      dalSegno: dalSegno,
      fine: fine,
      toCoda: toCoda,
      segno: segno,
      coda: coda,
    );

/// Performance order as measure NUMBERS, for readable expectations.
List<int> _played(List<Measure> ms) =>
    [for (final i in ParsedPiece.performanceOrder(ms)) ms[i].number];

String _xml(String measures) => '''<?xml version="1.0"?>
<score-partwise><part-list><score-part id="P1"/></part-list><part id="P1">
$measures
</part></score-partwise>''';

String _bar(int n, String extra) => '''<measure number="$n">
  ${n == 1 ? '<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>' : ''}
  <note><pitch><step>A</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
  $extra
</measure>''';

void main() {
  group('performanceOrder with navigation marks', () {
    test('D.C. al Fine returns to the start and stops at Fine', () {
      expect(
          _played([_m(1), _m(2, fine: true), _m(3), _m(4, daCapo: true)]),
          [1, 2, 3, 4, 1, 2]);
    });

    test('Fine is ignored before the jump', () {
      expect(_played([_m(1, fine: true), _m(2)]), [1, 2]);
    });

    test('repeats already taken fall through on the D.C. pass', () {
      expect(
          _played([
            _m(1, repeatStart: true),
            _m(2, repeatEnd: true, fine: true),
            _m(3, repeatStart: true),
            _m(4, repeatEnd: true, daCapo: true),
          ]),
          [1, 2, 1, 2, 3, 4, 3, 4, 1, 2]);
    });

    test('D.S. al Coda jumps to the segno, then skips to the coda', () {
      expect(
          _played([
            _m(1),
            _m(2, segno: true),
            _m(3, toCoda: true),
            _m(4, dalSegno: true),
            _m(5, coda: true),
            _m(6),
          ]),
          [1, 2, 3, 4, 2, 3, 5, 6]);
    });

    test('D.C. with no Fine plays through to the end once more', () {
      expect(_played([_m(1), _m(2, daCapo: true), _m(3)]), [1, 2, 1, 2, 3]);
    });

    test('no marks → unchanged simple repeats', () {
      expect(_played([_m(1), _m(2, repeatEnd: true), _m(3)]), [1, 2, 1, 2, 3]);
    });
  });

  group('MusicXmlParser reads navigation marks', () {
    test('from <sound> attributes', () {
      final p = MusicXmlParser().parse(_xml([
        _bar(1, '<direction><direction-type><segno/></direction-type><sound segno="s"/></direction>'),
        _bar(2, '<direction><direction-type><words>Fine</words></direction-type><sound fine="yes"/></direction>'),
        _bar(3, '<direction><direction-type><words>To Coda</words></direction-type><sound tocoda="c"/></direction>'),
        _bar(4, '<direction><direction-type><words>D.S. al Coda</words></direction-type><sound dalsegno="s"/></direction>'),
        _bar(5, '<direction><direction-type><coda/></direction-type><sound coda="c"/></direction>'),
        _bar(6, '<direction><direction-type><words>D.C. al Fine</words></direction-type><sound dacapo="yes"/></direction>'),
      ].join('\n')));
      final ms = p.measures;
      expect(ms[0].segno, isTrue);
      expect(ms[1].fine, isTrue);
      expect(ms[2].toCoda, isTrue);
      expect(ms[2].coda, isFalse);
      expect(ms[3].dalSegno, isTrue);
      expect(ms[4].coda, isTrue);
      expect(ms[5].daCapo, isTrue);
      // The "Fine" inside "D.C. al Fine" is not a Fine.
      expect(ms[5].fine, isFalse);
    });

    test('from words alone', () {
      final p = MusicXmlParser().parse(_xml([
        _bar(1, ''),
        _bar(2, '<direction><direction-type><words>Fine</words></direction-type></direction>'),
        _bar(3, '<direction><direction-type><words>D.C. al Fine</words></direction-type></direction>'),
      ].join('\n')));
      expect(_played(p.measures), [1, 2, 3, 1, 2]);
    });
  });

  // Golden fixtures, captured from the .abc beside them with the bundled
  // converter (`node scripts/abc_to_musicxml.cjs`), as in old_joe_clark_test.
  group('ABC imports', () {
    List<int> playedFixture(String name) => _played(MusicXmlParser()
        .parse(File('test/fixtures/$name.musicxml').readAsStringSync())
        .measures);

    test('!fine! and a !D.C.alfine! before the final barline', () {
      expect(playedFixture('dc_al_fine'),
          [1, 2, 1, 2, 3, 4, 5, 6, 5, 6, 7, 8, 1, 2, 3, 4]);
    });

    test('!segno!, a "^To Coda" annotation, !D.S.alcoda! and !coda!', () {
      expect(playedFixture('ds_al_coda'), [1, 2, 3, 4, 2, 3, 5, 6]);
    });
  });

  test('Gossec Gavotte plays its D.C. al Fine as the recording does', () {
    final p = MusicXmlParser()
        .parse(File('assets/fixtures/gossec_gavotte.xml').readAsStringSync());
    List<int> r(int a, int b) => [for (var n = a; n <= b; n++) n];
    expect(_played(p.measures), [
      ...r(1, 8), ...r(1, 8), ...r(9, 16),
      ...r(17, 24), ...r(17, 24), ...r(25, 32), ...r(25, 32),
      ...r(1, 8), ...r(9, 16),
    ]);
  });
}

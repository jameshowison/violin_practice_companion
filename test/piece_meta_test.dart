import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece_meta.dart';

String score({String key = '', String time = '', String creator = ''}) => '''
<?xml version="1.0"?>
<score-partwise>
  <identification>$creator</identification>
  <part id="P1"><measure number="1">
    <attributes><divisions>1</divisions>$key$time</attributes>
    <note><pitch><step>A</step><octave>4</octave></pitch></note>
  </measure>
  <measure number="2"><attributes><key><fifths>-3</fifths></key><time><beats>3</beats><beat-type>4</beat-type></time></attributes></measure>
  </part>
</score-partwise>''';

void main() {
  test('a card names the key after its signature, the mode shortened', () {
    PieceMeta m(String name, String sig) =>
        PieceMeta(keyShort: '', keyName: name, signature: sig, time: '');
    expect(cardKeyLabel(m('A major', '3♯')), '3♯ A maj.');
    expect(cardKeyLabel(m('D minor', '1♭')), '1♭ D min.');
    expect(cardKeyLabel(m('E dorian', '2♯')), '2♯ E dor.');
    expect(cardKeyLabel(m('F♯ minor', '3♯')), '3♯ F♯ min.');
    expect(cardKeyLabel(m('C major', 'no ♯/♭')), 'C maj.');
  });

  test('key, time and composer come from the header', () {
    final m = PieceMeta.fromHeader(score(
      key: '<key><fifths>3</fifths><mode>major</mode></key>',
      time: '<time><beats>6</beats><beat-type>8</beat-type></time>',
      creator: '<creator type="composer">Robert Schumann</creator>',
    ));

    expect(m.keyShort, 'A');
    expect(m.keyName, 'A major');
    expect(m.signature, '3♯');
    expect(m.time, '6/8');
    expect(m.composer, 'Robert Schumann');
  });

  test('a key change later in the piece does not count', () {
    // Measure 2 changes to three flats and 3/4; the list shows the opening.
    final m = PieceMeta.fromHeader(score(
      key: '<key><fifths>2</fifths></key>',
      time: '<time><beats>4</beats><beat-type>4</beat-type></time>',
    ));

    expect(m.keyName, 'D major');
    expect(m.time, '4/4');
  });

  test('modes and flats are named in full', () {
    expect(
        PieceMeta.fromHeader(score(key: '<key><fifths>-1</fifths><mode>minor</mode></key>'))
            .keyName,
        'D minor');
    expect(
        PieceMeta.fromHeader(score(key: '<key><fifths>-2</fifths></key>')).keyName,
        'B♭ major');
    expect(
        PieceMeta.fromHeader(score(key: '<key><fifths>2</fifths><mode>mixolydian</mode></key>'))
            .keyName,
        'A mixolydian');
    expect(
        PieceMeta.fromHeader(score(key: '<key><fifths>0</fifths><mode>minor</mode></key>'))
            .signature,
        'no ♯/♭');
  });

  test('no key is C major, no time is no time, and the catalog fills in a composer', () {
    final m = PieceMeta.fromHeader(score(), fallbackComposer: 'Traditional');

    expect(m.keyName, 'C major');
    expect(m.time, isNull);
    expect(m.composer, 'Traditional');
  });

  test("the score's own composer beats the catalog's", () {
    final m = PieceMeta.fromHeader(
      score(creator: '<creator type="composer">F.-J. Gossec &amp; co</creator>'),
      fallbackComposer: 'Traditional',
    );

    expect(m.composer, 'F.-J. Gossec & co');
  });

  test('every bundled score yields its key', () {
    final dir = Directory('assets/library');
    final scores = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('score.musicxml'));
    expect(scores, isNotEmpty);
    for (final f in scores) {
      final m = PieceMeta.fromHeader(f.readAsStringSync());
      expect(m.keyName, matches(RegExp(r'^[A-G][♭♯]? \w+$')), reason: f.path);
      expect(m.time, isNotNull, reason: f.path);
    }
  });
}

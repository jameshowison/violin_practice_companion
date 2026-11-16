// First/second endings (MusicXML `<ending>` voltas): parsing, and the
// performance order MIDI playback, the staff unfold and the aligner follow.

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

Measure _m(
  int number, {
  bool repeatStart = false,
  bool repeatEnd = false,
  bool daCapo = false,
  bool fine = false,
  Set<int> endings = const {},
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
      fine: fine,
      endings: endings,
    );

List<int> _played(List<Measure> ms) =>
    [for (final i in ParsedPiece.performanceOrder(ms)) ms[i].number];

String _xml(String measures) => '''<?xml version="1.0"?>
<score-partwise><part-list><score-part id="P1"/></part-list><part id="P1">
$measures
</part></score-partwise>''';

String _bar(int n, [String left = '', String right = '']) => '''<measure number="$n">
  ${n == 1 ? '<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>' : ''}
  ${left.isEmpty ? '' : '<barline location="left">$left</barline>'}
  <note><pitch><step>A</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
  ${right.isEmpty ? '' : '<barline location="right">$right</barline>'}
</measure>''';

void main() {
  group('performanceOrder with endings', () {
    test('|: 1-3 [1 4 :| [2 5 plays the first ending once', () {
      expect(
        _played([
          _m(1, repeatStart: true),
          _m(2),
          _m(3),
          _m(4, repeatEnd: true, endings: {1}),
          _m(5, endings: {2}),
        ]),
        [1, 2, 3, 4, 1, 2, 3, 5],
      );
    });

    test('repeat from the start (no |:) and music after the second ending',
        () {
      expect(
        _played([
          _m(1),
          _m(2, repeatEnd: true, endings: {1}),
          _m(3, endings: {2}),
          _m(4),
        ]),
        [1, 2, 1, 3, 4],
      );
    });

    test('multi-measure endings', () {
      expect(
        _played([
          _m(1, repeatStart: true),
          _m(2, endings: {1}),
          _m(3, repeatEnd: true, endings: {1}),
          _m(4, endings: {2}),
          _m(5, endings: {2}),
          _m(6),
        ]),
        [1, 2, 3, 1, 4, 5, 6],
      );
    });

    test('a first ending with no :| still repeats', () {
      expect(
        _played([
          _m(1, repeatStart: true),
          _m(2, endings: {1}),
          _m(3, endings: {2}),
        ]),
        [1, 2, 1, 3],
      );
    });

    test('an ending for passes 1 and 2, then a third', () {
      expect(
        _played([
          _m(1, repeatStart: true),
          _m(2, repeatEnd: true, endings: {1, 2}),
          _m(3, endings: {3}),
        ]),
        [1, 2, 1, 2, 1, 3],
      );
    });

    test('two strains, each with its own endings', () {
      expect(
        _played([
          _m(1, repeatStart: true),
          _m(2, repeatEnd: true, endings: {1}),
          _m(3, endings: {2}),
          _m(4, repeatStart: true),
          _m(5, repeatEnd: true, endings: {1}),
          _m(6, endings: {2}),
        ]),
        [1, 2, 1, 3, 4, 5, 4, 6],
      );
    });

    test('a later :| with no |: returns to the bar after the volta group', () {
      expect(
        _played([
          _m(1),
          _m(2, repeatEnd: true, endings: {1}),
          _m(3, endings: {2}),
          _m(4),
          _m(5, repeatEnd: true),
        ]),
        [1, 2, 1, 3, 4, 5, 4, 5],
      );
    });

    test('after D.C. the last ending is taken', () {
      expect(
        _played([
          _m(1, repeatStart: true),
          _m(2, repeatEnd: true, endings: {1}),
          _m(3, endings: {2}, fine: true),
          _m(4, daCapo: true),
        ]),
        [1, 2, 1, 3, 4, 1, 3],
      );
    });

    test('no endings: unchanged', () {
      expect(
        _played([_m(1, repeatStart: true), _m(2, repeatEnd: true), _m(3)]),
        [1, 2, 1, 2, 3],
      );
    });
  });

  group('MusicXmlParser reads <ending>', () {
    final parser = MusicXmlParser();

    test('single-measure first and second endings', () {
      final piece = parser.parse(_xml([
        _bar(1, '<repeat direction="forward"/>'),
        _bar(2),
        _bar(3, '<ending number="1" type="start"/>',
            '<bar-style>light-heavy</bar-style><ending number="1" type="stop"/><repeat direction="backward"/>'),
        _bar(4, '<ending number="2" type="start"/>',
            '<ending number="2" type="discontinue"/>'),
        _bar(5),
      ].join('\n')));
      expect([for (final m in piece.measures) m.endings], [
        <int>{},
        <int>{},
        {1},
        {2},
        <int>{},
      ]);
      expect(_played(piece.measures), [1, 2, 3, 1, 2, 4, 5]);
    });

    test('a bracket over several measures, numbered "1, 2"', () {
      final piece = parser.parse(_xml([
        _bar(1),
        _bar(2, '<ending number="1, 2" type="start"/>'),
        _bar(3, '', '<ending number="1, 2" type="stop"/>'),
        _bar(4),
      ].join('\n')));
      expect([for (final m in piece.measures) m.endings], [
        <int>{},
        {1, 2},
        {1, 2},
        <int>{},
      ]);
    });

    test('copyWithNotes keeps endings', () {
      final m = _m(1, endings: {2});
      expect(m.copyWithNotes(m.notes).endings, {2});
    });
  });

  group('MeasureXmlEditor.setMeasureEndings', () {
    final parser = MusicXmlParser();
    String score() => _xml([
          _bar(1, '<repeat direction="forward"/>'),
          _bar(2),
          _bar(3, '',
              '<bar-style>light-heavy</bar-style><repeat direction="backward"/>'),
          _bar(4),
          _bar(5),
        ].join('\n'));

    test('marking bar 3 as ending 1 and bar 4 as ending 2', () {
      var xml = MeasureXmlEditor.setMeasureEndings(score(), 3, {1});
      xml = MeasureXmlEditor.setMeasureEndings(xml, 4, {2});
      final piece = parser.parse(xml);
      expect([for (final m in piece.measures) m.endings],
          [<int>{}, <int>{}, {1}, {2}, <int>{}]);
      expect(_played(piece.measures), [1, 2, 3, 1, 2, 4, 5]);
      // Ending 1 closes with a hook, in the same barline as its :|; the
      // second ending is left open, as printed.
      expect(xml, contains('<ending number="1" type="stop"/><repeat'));
      expect(xml, contains('<ending number="2" type="discontinue"/>'));
      expect(RegExp('<barline location="right"').allMatches(xml).length, 2);
    });

    test('extending an ending over two bars makes one bracket', () {
      var xml = MeasureXmlEditor.setMeasureEndings(score(), 4, {2});
      xml = MeasureXmlEditor.setMeasureEndings(xml, 5, {2});
      expect(RegExp('type="start"').allMatches(xml).length, 1);
      expect(parser.parse(xml).measures.map((m) => m.endings).toList(),
          [<int>{}, <int>{}, <int>{}, {2}, {2}]);
    });

    test('clearing removes the bracket and leaves the repeat', () {
      var xml = MeasureXmlEditor.setMeasureEndings(score(), 3, {1});
      xml = MeasureXmlEditor.setMeasureEndings(xml, 3, {});
      expect(xml, isNot(contains('<ending')));
      expect(parser.parse(xml).measures[2].repeatEnd, isTrue);
    });

    test('toggling a repeat keeps an ending on the same barline', () {
      var xml = MeasureXmlEditor.setMeasureEndings(score(), 3, {1});
      xml = MeasureXmlEditor.setMeasureRepeats(xml, 3, start: false, end: false);
      expect(parser.parse(xml).measures[2].endings, {1});
      xml = MeasureXmlEditor.setMeasureRepeats(xml, 3, start: false, end: true);
      final m = parser.parse(xml).measures[2];
      expect(m.endings, {1});
      expect(m.repeatEnd, isTrue);
      expect(RegExp('<barline location="right"').allMatches(xml).length, 1);
    });
  });
}

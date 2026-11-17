import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/services/chord_editor.dart';
import 'package:violin_practice_companion/services/measure_edit_session.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/providers.dart';

/// Bowing marks are modelled ([NoteEvent.bowing]); slurs, articulations and
/// the like are carried ([NoteEvent.carriedNotations]). Both have to come
/// through a measure-editor rewrite, which rebuilds every `<note>` of the bar.

String _note(String step, int octave, {String notations = '', int dur = 4}) =>
    '<note><pitch><step>$step</step><octave>$octave</octave></pitch>'
    '<duration>$dur</duration><voice>1</voice><type>quarter</type>'
    '${notations.isEmpty ? '' : '<notations>$notations</notations>'}</note>';

String _score(List<String> bar1, [List<String>? bar2]) => '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>4</divisions>
        <key><fifths>0</fifths></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>
      ${bar1.join('\n      ')}
    </measure>${bar2 == null ? '' : '''
    <measure number="2">
      ${bar2.join('\n      ')}
    </measure>'''}
  </part>
</score-partwise>''';

void main() {
  final parser = MusicXmlParser();

  List<NoteEvent> bar(String xml, [int i = 0]) =>
      parser.parse(xml).measures[i].notes;

  /// Rewrites bar [n] of [xml] with [notes], the way Save does.
  String rewrite(String xml, List<NoteEvent> notes, [int n = 1]) =>
      MeasureXmlEditor.replaceMeasureNotes(xml, n, notes, 4);

  group('the parser', () {
    test('reads down-bow and up-bow, alongside a fingering', () {
      final notes = bar(_score([
        _note('G', 4,
            notations: '<technical><down-bow/><fingering>3</fingering>'
                '</technical>'),
        _note('A', 4, notations: '<technical><up-bow/></technical>'),
        _note('B', 4),
        _note('C', 5),
      ]));
      expect(notes.map((n) => n.bowing),
          [Bowing.down, Bowing.up, null, null]);
      expect(notes.first.scoreFinger, 3);
    });

    test('carries what it does not model, and nothing it does', () {
      final n = bar(_score([
        _note('G', 4,
            notations: '<slur type="start" number="1"/>'
                '<technical><down-bow/><fingering>3</fingering>'
                '<harmonic/></technical>'
                '<articulations><staccato/></articulations>'
                '<fermata/>'),
        _note('A', 4, notations: '<slur type="stop" number="1"/>'),
        _note('B', 4),
        _note('C', 5),
      ])).first;
      final carried = n.carriedNotations.join();
      expect(carried, contains('<slur type="start" number="1"/>'));
      expect(carried, contains('<staccato/>'));
      expect(carried, contains('<fermata/>'));
      // The technical comes through with only the mark nothing else holds.
      expect(carried, contains('<technical><harmonic/></technical>'));
      expect(carried, isNot(contains('fingering')));
      expect(carried, isNot(contains('down-bow')));
    });

    test('a note with no notations carries none', () {
      expect(bar(_score([_note('G', 4)])).single.carriedNotations, isEmpty);
    });
  });

  group('a rewrite keeps', () {
    final xml = _score([
      _note('G', 4,
          notations: '<slur type="start" number="1"/>'
              '<technical><down-bow/></technical>'),
      _note('A', 4, notations: '<slur type="stop" number="1"/>'),
      _note('B', 4,
          notations: '<technical><up-bow/></technical>'
              '<articulations><staccato/><accent/></articulations>'),
      _note('C', 5, notations: '<fermata type="upright"/>'),
    ]);

    test('every mark, when the bar is saved unchanged', () {
      final out = bar(rewrite(xml, bar(xml)));
      expect(out.map((n) => n.bowing), [Bowing.down, null, Bowing.up, null]);
      expect(out.map((n) => n.carriedNotations), bar(xml).map((n) => n.carriedNotations));
    });

    test('a note\'s marks through a change of its pitch', () {
      final notes = bar(xml);
      final b = notes[2];
      notes[2] = ChordEditor.repitch(b,
          pitch: 'D5', midiNumber: 74, octave: 5);
      final out = bar(rewrite(xml, notes));
      expect(out[2].pitch, 'D5');
      expect(out[2].bowing, Bowing.up);
      expect(out[2].carriedNotations.join(), contains('<staccato/>'));
    });

    test('the bowing with a fingering, in one <technical>', () {
      final notes = bar(xml);
      notes[0] = notes[0].copyWith(scoreFinger: 0);
      final note = XmlDocument.parse(rewrite(xml, notes))
          .findAllElements('note')
          .first;
      final technical = note.findAllElements('technical').single;
      expect(technical.childElements.map((e) => e.name.local),
          ['down-bow', 'fingering']);
    });

    test('a fermata over a rest', () {
      final notes = bar(xml);
      notes[3] = ChordEditor.toggleRest(notes, 3)[3];
      final out = XmlDocument.parse(rewrite(xml, notes))
          .findAllElements('note')
          .last;
      expect(out.findElements('rest'), isNotEmpty);
      expect(out.findAllElements('fermata'), isNotEmpty);
    });
  });

  group('a rest', () {
    test('is never bowed', () {
      final notes = bar(_score([
        _note('G', 4, notations: '<technical><down-bow/></technical>'),
        _note('A', 4),
        _note('B', 4),
        _note('C', 5),
      ]));
      final rested = ChordEditor.toggleRest(notes, 0);
      expect(rested[0].bowing, isNull);
    });
  });

  group('slurs whose other end is deleted', () {
    test('go, within a bar', () {
      final xml = _score([
        _note('G', 4, notations: '<slur type="start" number="1"/>'),
        _note('A', 4, notations: '<slur type="stop" number="1"/>'),
        _note('B', 4),
        _note('C', 5),
      ]);
      final notes = bar(xml)..removeAt(1);
      final out = rewrite(xml, notes);
      expect(XmlDocument.parse(out).findAllElements('slur'), isEmpty);
      // And the note that held it keeps no empty <notations> behind.
      expect(XmlDocument.parse(out).findAllElements('notations'), isEmpty);
    });

    test('go, across the barline', () {
      // The slur starts in bar 1 and ends in bar 2. Deleting its first note
      // leaves bar 2's stop with nothing to close.
      final xml = _score([
        _note('G', 4),
        _note('A', 4),
        _note('B', 4),
        _note('C', 5, notations: '<slur type="start" number="1"/>'),
      ], [
        _note('D', 5, notations: '<slur type="stop" number="1"/>', dur: 16),
      ]);
      final notes = bar(xml)..removeAt(3);
      final out = rewrite(xml, notes);
      expect(XmlDocument.parse(out).findAllElements('slur'), isEmpty);
    });

    test('but a slur already broken elsewhere is left alone', () {
      // Bar 2 holds a stray stop the edit had nothing to do with.
      final xml = _score([
        _note('G', 4, notations: '<slur type="start" number="1"/>'),
        _note('A', 4, notations: '<slur type="stop" number="1"/>'),
        _note('B', 4),
        _note('C', 5),
      ], [
        _note('D', 5, notations: '<slur type="stop" number="2"/>', dur: 16),
      ]);
      final out = rewrite(xml, bar(xml));
      final slurs = XmlDocument.parse(out).findAllElements('slur').toList();
      expect(slurs.length, 3);
    });

    test('and a chain of slurs, end to start on one note, stays whole', () {
      final xml = _score([
        _note('G', 4, notations: '<slur type="start" number="1"/>'),
        _note('A', 4,
            notations: '<slur type="stop" number="1"/>'
                '<slur type="start" number="1"/>'),
        _note('B', 4, notations: '<slur type="stop" number="1"/>'),
        _note('C', 5),
      ]);
      final out = rewrite(xml, bar(xml));
      expect(XmlDocument.parse(out).findAllElements('slur').length, 4);
    });
  });

  group('the editor', () {
    final xml = _score([
      _note('G', 4),
      _note('A', 4, notations: '<technical><up-bow/></technical>'),
      _note('B', 4),
      _note('C', 5),
    ]);
    const piece = Piece(
        id: 'p1', title: 'Test', musicXmlFilePath: '/nowhere.xml', sections: []);

    Future<MeasureEditController> open() async {
      final parsed = parser.parse(xml);
      final c = ProviderContainer(overrides: [
        parsedPieceProvider.overrideWith((ref) async => parsed),
      ]);
      addTearDown(c.dispose);
      c.read(selectedPieceProvider.notifier).state = piece;
      await c.read(parsedPieceProvider.future);
      final ctl = c.read(measureEditProvider.notifier)..start(1);
      return ctl;
    }

    test('marks the selected note, and tapping again clears it', () async {
      final ctl = await open();
      ctl.select(0);
      ctl.setBowing(Bowing.down);
      expect(ctl.state!.notes[0].bowing, Bowing.down);
      expect(ctl.state!.isDirty, isTrue);
      ctl.setBowing(Bowing.down);
      expect(ctl.state!.notes[0].bowing, isNull);
    });

    test('switches a note from up to down', () async {
      final ctl = await open();
      ctl.select(1);
      ctl.setBowing(Bowing.down);
      expect(ctl.state!.notes[1].bowing, Bowing.down);
    });

    test('marks nothing on a rest', () async {
      final ctl = await open();
      ctl.select(2);
      ctl.toggleRest();
      ctl.setBowing(Bowing.up);
      expect(ctl.state!.notes[2].bowing, isNull);
    });

    test('puts a chord member\'s bowing on its stem', () async {
      final ctl = await open();
      ctl.select(3);
      ctl.toggleStack(); // C5 joins B4's stem
      expect(ctl.state!.notes[3].isChord, isTrue);
      ctl.setBowing(Bowing.down);
      expect(ctl.state!.notes[2].bowing, Bowing.down);
      expect(ctl.state!.notes[3].bowing, isNull);
    });
  });
}

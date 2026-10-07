import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/abc_exporter.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/chord_editor.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Ties: a tied chain is one held note. Read from MusicXML `<tie>`/`<tied>`,
/// played by [MidiGenerator] as a single [ScheduledNote], and carried through
/// the measure editor and ABC export — without moving a single measure onset,
/// which is what saved audio alignments are keyed to.
NoteEvent _n(int midi, NoteValue v, {bool start = false, bool stop = false}) =>
    NoteEvent(
      pitch: 'A4',
      midiNumber: midi,
      octave: 4,
      noteValue: v,
      dotted: false,
      isRest: false,
      tieStart: start,
      tieStop: stop,
    );

NoteEvent _rest(NoteValue v) => NoteEvent(
      pitch: 'R',
      midiNumber: 0,
      octave: 4,
      noteValue: v,
      dotted: false,
      isRest: true,
    );

ParsedPiece _piece(List<Measure> measures) => ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      measures: measures,
      beatsPerMeasure: 2,
    );

Measure _m(int number, List<NoteEvent> notes,
        {bool repeatStart = false, bool repeatEnd = false}) =>
    Measure(
        number: number,
        notes: notes,
        repeatStart: repeatStart,
        repeatEnd: repeatEnd);

NoteEvent _untied(NoteEvent n) => n.copyWith(tieStart: false, tieStop: false);

void main() {
  final gen = MidiGenerator.forTest(ticksPerBeat: 480);
  final parser = MusicXmlParser();
  const q = NoteValue.quarter;

  group('MidiGenerator', () {
    test('a tie across the barline sounds as one held note', () {
      // 2/4 at 60 bpm: | C D- | D E |  → C, D held for 2 s, E.
      final piece = _piece([
        _m(1, [_n(60, q), _n(62, q, start: true)]),
        _m(2, [_n(62, q, stop: true), _n(64, q)]),
      ]);
      final d = gen.generate(piece, 60);
      expect(d.notes.map((n) => (n.midiNote, n.onsetSeconds, n.offsetSeconds)),
          [(60, 0.0, 1.0), (62, 1.0, 3.0), (64, 3.0, 4.0)]);
      // Every notehead still gets its event; the held one says so.
      expect(d.highlightEvents.length, 4);
      expect(d.highlightEvents.map((e) => e.isTieContinuation),
          [false, false, true, false]);
    });

    test('a chain of three is still one note', () {
      final piece = _piece([
        _m(1, [_n(67, q, start: true), _n(67, q, start: true, stop: true)]),
        _m(2, [_n(67, q, stop: true), _rest(q)]),
      ]);
      final d = gen.generate(piece, 60);
      expect(d.notes.length, 1);
      expect(d.notes.single.offsetSeconds, closeTo(3.0, 1e-9));
    });

    test('a tie to a different pitch, or across a rest, is struck again', () {
      final wrongPitch = gen.generate(
          _piece([
            _m(1, [_n(60, q, start: true), _n(62, q, stop: true)])
          ]),
          60);
      expect(wrongPitch.notes.length, 2);
      final overRest = gen.generate(
          _piece([
            _m(1, [_n(60, q, start: true), _rest(q)]),
            _m(2, [_n(60, q, stop: true), _n(60, q)]),
          ]),
          60);
      expect(overRest.notes.length, 3);
    });

    test('ties follow performance order through a repeat', () {
      // |: A B- :| B C  — B tied out of the repeated bar. On the first pass
      // playback goes back to A, so B is struck again there; on the second it
      // runs on into bar 2's B, where the tie joins.
      final piece = _piece([
        _m(1, [_n(57, q), _n(59, q, start: true)],
            repeatStart: true, repeatEnd: true),
        _m(2, [_n(59, q, stop: true), _n(60, q)]),
      ]);
      final d = gen.generate(piece, 60);
      expect(d.notes.map((n) => (n.midiNote, n.onsetSeconds, n.offsetSeconds)),
          [(57, 0.0, 1.0), (59, 1.0, 2.0), (57, 2.0, 3.0), (59, 3.0, 5.0),
           (60, 5.0, 6.0)]);
    });

    test('ties move no measure onset and no highlight time', () {
      // Audio alignment anchors are measure onsets at the generation bpm, and
      // the cursor runs off the highlight events, so both must be identical
      // with and without ties.
      final xml = File('test/fixtures/gundagai_lyrics.musicxml').readAsStringSync();
      final tied = parser.parse(MusicXmlNormalizer.toSoundingPitch(xml));
      final untied = ParsedPiece(
        keySignature: tied.keySignature,
        keyFifths: tied.keyFifths,
        keyMode: tied.keyMode,
        divisions: tied.divisions,
        beatsPerMeasure: tied.beatsPerMeasure,
        beatType: tied.beatType,
        measures: [
          for (final m in tied.measures)
            m.copyWithNotes(m.notes.map(_untied).toList()),
        ],
      );
      final a = gen.generate(tied, 100), b = gen.generate(untied, 100);
      expect(a.measureOnsetSeconds, b.measureOnsetSeconds);
      expect(a.totalDurationSeconds, b.totalDurationSeconds);
      expect(a.highlightEvents.map((e) => e.onsetSeconds),
          b.highlightEvents.map((e) => e.onsetSeconds));
      // Every tied continuation is one strike fewer — eight in Gundagai, where
      // a chain like `G2-|G8-|G4` holds through two of them.
      final stops = tied.allNotes.where((n) => n.tieStop).length;
      expect(stops, greaterThan(0));
      expect(a.notes.length, b.notes.length - stops);
    });
  });

  group('parser', () {
    String bar(String notes) => '''
<score-partwise version="3.1"><part-list><score-part id="P1"/></part-list>
<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
$notes</measure></part></score-partwise>''';
    const pitch = '<pitch><step>C</step><octave>4</octave></pitch>';

    test('reads <tie>, and falls back to the <tied> arc alone', () {
      final notes = parser.parse(bar('''
<note>$pitch<duration>1</duration><tie type="start"/><type>quarter</type></note>
<note>$pitch<duration>1</duration><tie type="stop"/><tie type="start"/><type>quarter</type></note>
<note>$pitch<duration>1</duration><type>quarter</type><notations><tied type="stop"/></notations></note>
''')).allNotes;
      expect(notes.map((n) => (n.tieStart, n.tieStop)),
          [(true, false), (true, true), (false, true)]);
    });

    test('the converter writes Gundagai\'s ties, ends matched', () {
      final piece = parser.parse(MusicXmlNormalizer.toSoundingPitch(
          File('test/fixtures/gundagai.musicxml').readAsStringSync()));
      final notes = piece.allNotes.where((n) => !n.isRest).toList();
      expect(notes.where((n) => n.tieStart), isNotEmpty);
      for (var i = 0; i < notes.length; i++) {
        if (!notes[i].tieStart) continue;
        expect(notes[i + 1].tieStop, isTrue, reason: 'note $i');
        expect(notes[i + 1].midiNumber, notes[i].midiNumber, reason: 'note $i');
      }
    });
  });

  group('editing', () {
    final xml = File('test/fixtures/gundagai.musicxml').readAsStringSync();
    final piece = parser.parse(xml);
    // Bar 7 of Gundagai: `c2B4 G2-`, tied into bar 8's `G8-`.
    final bar7 = piece.measures[6].notes;

    test('a saved bar keeps its ties', () {
      expect(bar7.last.tieStart, isTrue);
      final out = parser
          .parse(MeasureXmlEditor.replaceMeasureNotes(xml, 7, bar7, 96))
          .measures[6]
          .notes;
      expect(out.last.tieStart, isTrue);
      expect(out.map((n) => n.tieStart), bar7.map((n) => n.tieStart));
    });

    test('a new pitch, or a rest, drops the tie', () {
      final i = bar7.length - 1;
      final repitched =
          ChordEditor.repitch(bar7[i], pitch: 'A4', midiNumber: 69, octave: 4);
      expect(repitched.tieStart, isFalse);
      expect(ChordEditor.toggleRest(bar7, i)[i].tieStart, isFalse);
    });

    test('ABC export writes the tie back as `-`', () {
      final abc = AbcExporter.export(piece, title: 'Gundagai');
      expect(abc, contains('"G"G2- | G8- |'));
    });
  });

  group('alignment', () {
    test('a barline held across by a tie is interpolated, not trusted', () {
      // | C D- | D E | F G |  at 60 bpm: bar 2 opens inside the held D.
      final piece = _piece([
        _m(1, [_n(60, q), _n(62, q, start: true)]),
        _m(2, [_n(62, q, stop: true), _n(64, q)]),
        _m(3, [_n(65, q), _n(67, q)]),
      ]);
      final midi = gen.generate(piece, 60);
      // DTW's guess for bar 2 is squeezed right up against bar 1.
      final anchors = [
        const ScoreAudioAnchor(0, 10.0),
        const ScoreAudioAnchor(2000, 10.2),
        const ScoreAudioAnchor(4000, 14.0),
      ];
      final held = AudioScoreAutoAligner.heldBarlines(midi, anchors);
      expect(held, [false, true, false]);
      final placed = AudioScoreAutoAligner.interpolateHeld(anchors, held);
      expect(placed[1].audioSec, closeTo(12.0, 1e-9));
      expect(placed[0].audioSec, 10.0);
      expect(placed[2].audioSec, 14.0);
    });

    test('a struck barline, or a held one at the very end, is left alone', () {
      final piece = _piece([
        _m(1, [_n(60, q), _n(62, q)]),
        _m(2, [_n(64, q), _n(65, q, start: true)]),
        _m(3, [_n(65, q, stop: true), _rest(q)]),
      ]);
      final anchors = [
        const ScoreAudioAnchor(0, 0),
        const ScoreAudioAnchor(2000, 2.5),
        const ScoreAudioAnchor(4000, 4.1),
      ];
      final held =
          AudioScoreAutoAligner.heldBarlines(gen.generate(piece, 60), anchors);
      expect(held, [false, false, true]);
      expect(AudioScoreAutoAligner.interpolateHeld(anchors, held)[2].audioSec,
          4.1);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/chord_palette.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';

NoteEvent _n({String? chord}) => NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: false,
      chordSymbol: chord,
    );

/// A 4-note measure. [chords] maps note index → the chord starting there.
Measure _m(int number, {Map<int, String> chords = const {}, int count = 4}) =>
    Measure(
      number: number,
      notes: [for (var i = 0; i < count; i++) _n(chord: chords[i])],
    );

ParsedPiece _piece(List<Measure> measures,
        {int fifths = 2, KeyMode mode = KeyMode.mixolydian}) =>
    ParsedPiece(
      keySignature: 'Amix',
      keyFifths: fifths,
      keyMode: mode,
      measures: measures,
    );

void main() {
  group('chordRunRegions', () {
    test('a run holds until the next chord and to the end of the piece', () {
      final measures = [
        _m(1, chords: {0: 'A'}),
        _m(2),
        _m(3, chords: {0: 'E'}),
        _m(4),
      ];
      final piece = _piece(measures);
      final regions =
          chordRunRegions([for (final m in measures) m.number], piece);

      expect(regions.length, 2);
      // A covers engraved indices 0..1 whole (E starts at the bar line of 2).
      expect(regions[0].startMeasureIndex, 0);
      expect(regions[0].startNote, 0);
      expect(regions[0].endMeasureIndex, 1);
      expect(regions[0].endNote, -1);
      // E runs to the end of the piece.
      expect(regions[1].startMeasureIndex, 2);
      expect(regions[1].endMeasureIndex, 3);
      expect(regions[1].endNote, -1);
    });

    test('a mid-measure change carries note-level edges', () {
      // Old Joe Clark bar 8: `A2 c2 "E"B2 G2` — E takes over on beat 3.
      final measures = [
        _m(1, chords: {0: 'A'}),
        _m(2, chords: {2: 'E'}),
        _m(3),
      ];
      final piece = _piece(measures);
      final regions =
          chordRunRegions([for (final m in measures) m.number], piece);

      expect(regions.length, 2);
      // A ends inside engraved measure 1, exclusive of note 2.
      expect(regions[0].endMeasureIndex, 1);
      expect(regions[0].endNote, 2);
      // E starts on note 2 of that same measure.
      expect(regions[1].startMeasureIndex, 1);
      expect(regions[1].startNote, 2);
    });

    test('measures before the first chord get no region', () {
      final measures = [_m(1), _m(2, chords: {0: 'A'})];
      final regions = chordRunRegions(
          [for (final m in measures) m.number], _piece(measures));
      expect(regions.length, 1);
      expect(regions.single.startMeasureIndex, 1);
    });

    test('a piece with no chords yields nothing', () {
      final measures = [_m(1), _m(2)];
      expect(
        chordRunRegions([for (final m in measures) m.number], _piece(measures)),
        isEmpty,
      );
    });

    test('labels are degree-primary and carry degree + quality', () {
      // A mixolydian: A = I, E = V, G = ♭VII, Bm = ii.
      final measures = [
        _m(1, chords: {0: 'A'}),
        _m(2, chords: {0: 'E'}),
        _m(3, chords: {0: 'G'}),
        _m(4, chords: {0: 'Bm'}),
      ];
      final regions = chordRunRegions(
          [for (final m in measures) m.number], _piece(measures));

      expect(regions.map((r) => r.label).toList(),
          ['I (A)', 'V (E)', '♭VII (G)', 'ii (Bm)']);
      expect(regions.map((r) => r.degree).toList(), [0, 4, 6, 1]);
      expect(regions.map((r) => r.minorQuality).toList(),
          [false, false, false, true]);
    });

    test('an unanalyzable chord name still gets a bar, with no degree', () {
      final measures = [_m(1, chords: {0: 'N.C.'})];
      final regions = chordRunRegions(
          [for (final m in measures) m.number], _piece(measures));
      expect(regions.single.label, 'N.C.');
      expect(regions.single.degree, isNull);
    });
  });
}

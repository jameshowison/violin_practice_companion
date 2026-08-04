import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/fingering_density.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/note_number_mode.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/string_label_style.dart';
import 'package:violin_practice_companion/services/fingering_annotation_builder.dart';

NoteEvent _n(String? string, String? finger,
        {bool rest = false, bool chord = false, int midi = 69}) =>
    NoteEvent(
      pitch: 'A4',
      midiNumber: midi,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: rest,
      fingerString: string,
      fingerNumber: finger,
      isChord: chord,
    );

ParsedPiece _piece(List<Measure> measures) => ParsedPiece(
      keySignature: 'A',
      keyFifths: 3,
      keyMode: KeyMode.major,
      measures: measures,
    );

List<FingeringAnnotation> _build(
  List<Measure> measures, {
  FingeringDensity density = FingeringDensity.all,
  FingeringDensityPolicy policy = FingeringDensityPolicy.difficulty,
  bool colourByString = true,
  StringLabelStyle stringLabelStyle = StringLabelStyle.always,
  NoteNumberMode numberMode = NoteNumberMode.violinFingering,
  FretStyle fretStyle = FretStyle.openStrings,
}) =>
    fingeringAnnotations(
      [for (final m in measures) m.number],
      _piece(measures),
      density: density,
      policy: policy,
      colourByString: colourByString,
      stringLabelStyle: stringLabelStyle,
      numberMode: numberMode,
      fretStyle: fretStyle,
    );

void main() {
  group('labels', () {
    final measures = [
      Measure(number: 1, notes: [_n('A', '1'), _n('A', '2L'), _n('E', '3H')]),
    ];

    test('colours on drop the string letter, keeping the L/H suffix', () {
      final out = _build(measures);
      expect([for (final a in out) a.label], ['1', '2L', '3H']);
      // The string is still carried, as the chip's fill.
      expect([for (final a in out) a.string], ['A', 'A', 'E']);
    });

    test('colours off, style "always" prefixes every label', () {
      final out = _build(measures, colourByString: false);
      expect([for (final a in out) a.label], ['A1', 'A2L', 'E3H']);
    });

    test('colours off, style "onChange" prefixes only at a change', () {
      final out = _build(measures,
          colourByString: false, stringLabelStyle: StringLabelStyle.onChange);
      // First note counts as a change (nothing precedes it); the second stays on
      // A so it loses the letter; the third moves to E so it regains it.
      expect([for (final a in out) a.label], ['A1', '2L', 'E3H']);
    });

    test('colours off, style "never" gives bare finger numbers', () {
      final out = _build(measures,
          colourByString: false, stringLabelStyle: StringLabelStyle.never);
      expect([for (final a in out) a.label], ['1', '2L', '3H']);
    });

    test('an L/H suffix is never rewritten to an accidental sign', () {
      final out = _build(measures);
      for (final a in out) {
        expect(a.label, isNot(contains('♭')));
        expect(a.label, isNot(contains('♯')));
      }
      expect(out[1].label, '2L');
    });
  });

  group('indices', () {
    test('note index is the positional index within the measure, rests counted',
        () {
      final measures = [
        Measure(number: 1, notes: [
          _n(null, null, rest: true),
          _n('A', '1'),
          _n(null, null, rest: true),
          _n('A', '3'),
        ]),
        Measure(number: 2, notes: [_n('E', '0')]),
      ];
      final out = _build(measures);
      expect([for (final a in out) (a.measureIndex, a.noteIndex)],
          [(0, 1), (0, 3), (1, 0)]);
    });

    test('a chord member is skipped but still consumes its index', () {
      final measures = [
        Measure(number: 1, notes: [
          _n('D', '1'),
          _n('A', '3', chord: true), // stacked on the same stem, same x
          _n('A', '0'),
        ]),
      ];
      final out = _build(measures);
      // The third note keeps index 2 — the chord member was not renumbered away.
      expect([for (final a in out) (a.noteIndex, a.label)], [(0, '1'), (2, '0')]);
    });

    test('notes with no fingering data produce nothing', () {
      final measures = [
        Measure(number: 1, notes: [_n(null, null), _n('A', '1')]),
      ];
      expect(_build(measures).length, 1);
    });

    test('measure numbers map through to engraved indices', () {
      // A pickup numbered 0, so number != index.
      final measures = [
        Measure(number: 0, notes: [_n('A', '1')]),
        Measure(number: 1, notes: [_n('A', '2')]),
      ];
      final out = _build(measures);
      expect([for (final a in out) a.measureIndex], [0, 1]);
    });
  });

  group('density', () {
    // A1 A1 A1 | A2 E1 E1
    final measures = [
      Measure(number: 1, notes: [_n('A', '1'), _n('A', '1'), _n('A', '1')]),
      Measure(number: 2, notes: [_n('A', '2'), _n('E', '1'), _n('E', '1')]),
    ];

    test('"all" labels every fingered note', () {
      expect(_build(measures).length, 6);
    });

    test('"fewer" drops the repeats', () {
      final out = _build(measures, density: FingeringDensity.fewer);
      // Kept: the opening A1, the A2 (measure start + changed), the E1 (string
      // change). Dropped: the two A1 repeats and the trailing E1 repeat.
      expect([for (final a in out) (a.measureIndex, a.noteIndex)],
          [(0, 0), (1, 0), (1, 1)]);
    });

    test('"least" keeps the opening note and the string change', () {
      final out = _build(measures, density: FingeringDensity.least);
      expect([for (final a in out) (a.measureIndex, a.noteIndex)],
          [(0, 0), (1, 1)]);
    });

    test('density never changes a label, only whether it appears', () {
      // The `onChange` letter is placed from the previous note in the MUSIC, not
      // the previous note that got a label — so a hidden note can't shift a
      // letter onto or off the notes around it.
      final byDensity = {
        for (final d in FingeringDensity.values)
          d: _build(measures,
              density: d,
              colourByString: false,
              stringLabelStyle: StringLabelStyle.onChange),
      };
      final all = {
        for (final a in byDensity[FingeringDensity.all]!)
          (a.measureIndex, a.noteIndex): a.label,
      };
      for (final d in FingeringDensity.values) {
        for (final a in byDensity[d]!) {
          expect(a.label, all[(a.measureIndex, a.noteIndex)],
              reason: 'label for ${a.measureIndex}/${a.noteIndex} changed at $d');
        }
      }
      // And the string change still carries its letter at the tightest level.
      expect(byDensity[FingeringDensity.least]!.last.label, 'E1');
    });
  });

  group('mandolin frets', () {
    // The G string, fingers 0-4: G3 A3 B3 C4 D4.
    final gString = [
      Measure(number: 1, notes: [
        _n('G', '0', midi: 55),
        _n('G', '1', midi: 57),
        _n('G', '2', midi: 59),
        _n('G', '3', midi: 60),
        _n('G', '4', midi: 62),
      ]),
    ];

    test('"match fingering" changes the digits but not the strings', () {
      final fingering = _build(gString);
      expect([for (final a in fingering) a.label], ['0', '1', '2', '3', '4']);

      final frets = _build(gString,
          numberMode: NoteNumberMode.mandolinFret,
          fretStyle: FretStyle.matchFingering);
      expect([for (final a in frets) a.label], ['0', '2', '4', '5', '7']);
      // Same strings — so in the channel every chip keeps its colour, which is
      // the reason this option exists.
      expect([for (final a in frets) a.string],
          [for (final a in fingering) a.string]);
    });

    test('"open strings" keeps frets low by moving the note to a new string',
        () {
      final frets = _build(gString,
          numberMode: NoteNumberMode.mandolinFret,
          fretStyle: FretStyle.openStrings);
      // D4 becomes the open D rather than G7 — and so changes colour.
      expect([for (final a in frets) a.label], ['0', '2', '4', '5', '0']);
      expect([for (final a in frets) a.string],
          ['G', 'G', 'G', 'G', 'D']);
    });

    test('the string letter follows the fret\'s string, not the fingering\'s',
        () {
      final frets = _build(gString,
          colourByString: false,
          numberMode: NoteNumberMode.mandolinFret,
          fretStyle: FretStyle.openStrings);
      expect([for (final a in frets) a.label],
          ['G0', 'G2', 'G4', 'G5', 'D0']);
    });

    test('"on change" tracks the shown string, so a moved note regains its letter',
        () {
      final frets = _build(gString,
          colourByString: false,
          stringLabelStyle: StringLabelStyle.onChange,
          numberMode: NoteNumberMode.mandolinFret,
          fretStyle: FretStyle.openStrings);
      expect([for (final a in frets) a.label], ['G0', '2', '4', '5', 'D0']);
    });

    test('the number mode changes labels only, never which notes are labelled',
        () {
      // Same notes at every density, under both number modes — the density rules
      // stay keyed to the violin fingering.
      for (final d in FingeringDensity.values) {
        final fingering = _build(gString, density: d);
        for (final style in FretStyle.values) {
          final frets = _build(gString,
              density: d,
              numberMode: NoteNumberMode.mandolinFret,
              fretStyle: style);
          expect([for (final a in frets) (a.measureIndex, a.noteIndex)],
              [for (final a in fingering) (a.measureIndex, a.noteIndex)],
              reason: 'fret mode changed the selection at $d / $style');
        }
      }
    });

    test('a fret is a plain number — no L/H suffix to carry', () {
      // F4 on the D string is the violin's low 2nd finger; as a fret it is just
      // 3, because a fret names the semitone exactly.
      final measures = [
        Measure(number: 1, notes: [_n('D', '2L', midi: 65)]),
      ];
      expect(_build(measures).single.label, '2L');
      expect(
          _build(measures,
                  numberMode: NoteNumberMode.mandolinFret,
                  fretStyle: FretStyle.matchFingering)
              .single
              .label,
          '3');
    });
  });

  group('stringRunRegions', () {
    List<StringRunRegion> runs(
      List<Measure> measures, {
      NoteNumberMode numberMode = NoteNumberMode.violinFingering,
      FretStyle fretStyle = FretStyle.openStrings,
    }) =>
        stringRunRegions([for (final m in measures) m.number], _piece(measures),
            numberMode: numberMode, fretStyle: fretStyle);

    test('consecutive notes on one string are a single run', () {
      final measures = [
        Measure(number: 1, notes: [_n('G', '0'), _n('G', '1'), _n('G', '2')]),
        Measure(number: 2, notes: [_n('G', '3'), _n('D', '1'), _n('D', '2')]),
      ];
      final r = runs(measures);
      expect(r.length, 2);
      expect(r[0].string, 'G');
      expect(r[0].startMeasureIndex, 0);
      expect(r[0].startNote, 0);
      // Ends exclusive of the D that starts mid-measure-2.
      expect(r[0].endMeasureIndex, 1);
      expect(r[0].endNote, 1);
      expect(r[1].string, 'D');
      expect(r[1].startMeasureIndex, 1);
      expect(r[1].startNote, 1);
      expect(r[1].endNote, -1); // to the end of the piece
    });

    test('a rest does not break a run — the bow lifts, the hand stays', () {
      final measures = [
        Measure(number: 1, notes: [
          _n('A', '1'),
          _n(null, null, rest: true),
          _n('A', '2'),
        ]),
      ];
      final r = runs(measures);
      expect(r.length, 1);
      expect(r.single.string, 'A');
    });

    test('returning to a string after leaving it starts a new run', () {
      final measures = [
        Measure(number: 1, notes: [_n('A', '1'), _n('E', '1'), _n('A', '2')]),
      ];
      expect([for (final x in runs(measures)) x.string], ['A', 'E', 'A']);
    });

    test('the runs are independent of the density filter', () {
      // The whole point: at "Least" almost every number is gone, but the track
      // still spans every note.
      final measures = [
        Measure(number: 1, notes: [_n('G', '1'), _n('G', '1'), _n('G', '1')]),
      ];
      expect(runs(measures).single.endNote, -1);
      expect(_build(measures, density: FingeringDensity.least).length, 1,
          reason: 'only the opening note keeps a label at Least…');
      expect(runs(measures).length, 1,
          reason: '…but the run still covers all three notes');
    });

    test('open-string fret mode can split a run the fingering would not', () {
      // G string fingers 3 then 4: under the fingering both are G, but the 4th
      // finger resolves to the open D, so the track changes colour there.
      final measures = [
        Measure(number: 1, notes: [
          _n('G', '3', midi: 60),
          _n('G', '4', midi: 62),
        ]),
      ];
      expect([for (final x in runs(measures)) x.string], ['G']);
      expect([
        for (final x in runs(measures,
            numberMode: NoteNumberMode.mandolinFret,
            fretStyle: FretStyle.openStrings))
          x.string
      ], ['G', 'D']);
      // Matching the fingering keeps it one run, as it does the chip colours.
      expect([
        for (final x in runs(measures,
            numberMode: NoteNumberMode.mandolinFret,
            fretStyle: FretStyle.matchFingering))
          x.string
      ], ['G']);
    });

    test('notes with no fingering data contribute no run', () {
      expect(runs([
        Measure(number: 1, notes: [_n(null, null), _n(null, null)])
      ]), isEmpty);
      expect(runs(const []), isEmpty);
    });
  });

  test('an empty piece yields nothing', () {
    expect(_build(const []), isEmpty);
  });
}

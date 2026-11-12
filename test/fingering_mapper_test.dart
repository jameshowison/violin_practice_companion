import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/note_number_mode.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/fingering_mapper.dart';

// Test fingering logic inline without asset loading.
// Mirrors the algorithm in fingering_mapper.dart.

typedef FingeringEntry = ({String string, String finger, Map<String, String>? alt});

({String string, String finger}) resolveFingeringEntry(
    FingeringEntry entry, String preference) {
  final alt = entry.alt;
  if (alt != null) {
    final altFinger = alt['finger']!;
    final altString = alt['string']!;
    if (preference == 'open' && altFinger == '0') {
      return (string: altString, finger: altFinger);
    }
    if (preference == 'fingered' && entry.finger == '0') {
      return (string: altString, finger: altFinger);
    }
  }
  return (string: entry.string, finger: entry.finger);
}

void main() {
  _realMapperTests();
  // G4 = MIDI 62: G-string finger 4, alt D-string open (finger "0")
  final g4Entry = (
    string: 'G',
    finger: '4',
    alt: {'string': 'D', 'finger': '0'},
  );

  test('G4 prefers fingered (G4 = G-string finger 4)', () {
    final r = resolveFingeringEntry(g4Entry, 'fingered');
    expect(r.string, 'G');
    expect(r.finger, '4');
  });

  test('G4 prefers open (D-string open)', () {
    final r = resolveFingeringEntry(g4Entry, 'open');
    expect(r.string, 'D');
    expect(r.finger, '0');
  });

  // D4 = MIDI 62 on D string is open: primary open, alt fingered
  // G-string open (MIDI 55)
  final g3Open = (
    string: 'G',
    finger: '0',
    alt: null,
  );

  test('G3 (open G) has no alt — always open regardless of preference', () {
    final rFingered = resolveFingeringEntry(g3Open, 'fingered');
    expect(rFingered.string, 'G');
    expect(rFingered.finger, '0');
    final rOpen = resolveFingeringEntry(g3Open, 'open');
    expect(rOpen.string, 'G');
    expect(rOpen.finger, '0');
  });

  // A4 = MIDI 69: D-string finger 4, alt A-string open
  final a4Entry = (
    string: 'D',
    finger: '4',
    alt: {'string': 'A', 'finger': '0'},
  );

  test('A4 fingered stays on D string finger 4', () {
    final r = resolveFingeringEntry(a4Entry, 'fingered');
    expect(r.string, 'D');
    expect(r.finger, '4');
  });

  test('A4 open goes to A-string open', () {
    final r = resolveFingeringEntry(a4Entry, 'open');
    expect(r.string, 'A');
    expect(r.finger, '0');
  });

  // E4 = MIDI 64: D-string finger 1
  final e4Entry = (
    string: 'D',
    finger: '1',
    alt: null,
  );

  test('E4 D-string finger 1 regardless of preference', () {
    final r = resolveFingeringEntry(e4Entry, 'open');
    expect(r.string, 'D');
    expect(r.finger, '1');
    final r2 = resolveFingeringEntry(e4Entry, 'fingered');
    expect(r2.string, 'D');
    expect(r2.finger, '1');
  });
}

// The real mapper, against the bundled table, under each piece setting.
void _realMapperTests() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NoteEvent note(int midi,
          {int? finger,
          bool rest = false,
          bool chord = false,
          bool tieStart = false,
          bool tieStop = false}) =>
      NoteEvent(
        pitch: 'A4',
        midiNumber: midi,
        octave: 4,
        noteValue: NoteValue.quarter,
        dotted: false,
        isRest: rest,
        scoreFinger: finger,
        isChord: chord,
        tieStart: tieStart,
        tieStop: tieStop,
      );
  ParsedPiece bars(List<List<NoteEvent>> measures) => ParsedPiece(
        keySignature: 'D',
        keyFifths: 2,
        keyMode: KeyMode.major,
        measures: [
          for (var i = 0; i < measures.length; i++)
            Measure(number: i + 1, notes: measures[i])
        ],
      );
  ParsedPiece piece(List<int> midis) =>
      bars([[for (final m in midis) note(m)]]);
  List<String> labels(ParsedPiece p) => [
        for (final n in p.measures.expand((m) => m.notes))
          if (!n.isRest) '${n.fingerString}${n.fingerNumber}'
      ];

  late FingeringMapper mapper;
  setUpAll(() async {
    mapper = FingeringMapper();
    await mapper.init();
  });

  group('FingeringMapper.map', () {
    // D4, A4, E5: each an open string or a 4th finger below. B4 has no choice.
    const midis = [62, 69, 76, 71];

    test('open strings under Auto when nothing calls for the 4th', () {
      expect(labels(mapper.map(piece(midis))), ['D0', 'A0', 'E0', 'A1']);
    });

    test('open strings when the piece prefers them', () {
      expect(
          labels(mapper.map(piece(midis),
              preference: ViolinStringPreference.openStrings)),
          ['D0', 'A0', 'E0', 'A1']);
    });

    test('4th finger when the piece prefers it', () {
      expect(
          labels(mapper.map(piece(midis),
              preference: ViolinStringPreference.fourthFinger)),
          ['G4', 'D4', 'A4', 'A1']);
    });

    test('only D4, A4 and E5 have the choice', () {
      expect([for (var m = 50; m < 90; m++) if (FingeringMapper.hasFourthFingerChoice(m)) m],
          [62, 69, 76]);
    });
  });

  group('Auto: 4th finger for a neighbour note on the string below', () {
    test('D5 E5 D5 and G4 A4 G4 take the 4th', () {
      expect(labels(mapper.map(piece([74, 76, 74]))), ['A3', 'A4', 'A3']);
      expect(labels(mapper.map(piece([67, 69, 67]))), ['D3', 'D4', 'D3']);
    });

    test('a half step below counts too (D#5 E5 D#5)', () {
      expect(labels(mapper.map(piece([75, 76, 75]))), ['A3H', 'A4', 'A3H']);
    });

    test('a beginner tune stays open: C#5 E5, and D5 E5 F#5', () {
      expect(labels(mapper.map(piece([73, 76, 76, 73]))),
          ['A2', 'E0', 'E0', 'A2']);
      expect(labels(mapper.map(piece([74, 76, 78]))), ['A3', 'E0', 'E1']);
    });

    test('a repeated note is one run, fingered alike', () {
      expect(labels(mapper.map(piece([74, 76, 76, 76, 74]))),
          ['A3', 'A4', 'A4', 'A4', 'A3']);
    });

    test('the melody runs across a barline', () {
      final p = bars([
        [note(74)],
        [note(76), note(74)],
      ]);
      expect(labels(mapper.map(p)), ['A3', 'A4', 'A3']);
    });

    test('a rest or a chord breaks it', () {
      expect(labels(mapper.map(bars([[note(74), note(0, rest: true), note(76), note(74)]]))),
          ['A3', 'E0', 'A3']);
      expect(labels(mapper.map(bars([[note(74), note(76), note(66, chord: true), note(74)]]))),
          ['A3', 'E0', 'D2', 'A3']);
    });

    test('the first and last notes of the piece have one side only', () {
      expect(labels(mapper.map(piece([76, 74]))), ['E0', 'A3']);
    });
  });

  group('A note\'s own fingering pins the choice', () {
    test('4 beats open strings, 0 beats the 4th finger and Auto', () {
      expect(
          labels(mapper.map(bars([[note(76, finger: 4)]]),
              preference: ViolinStringPreference.openStrings)),
          ['A4']);
      expect(
          labels(mapper.map(bars([[note(76, finger: 0)]]),
              preference: ViolinStringPreference.fourthFinger)),
          ['E0']);
      expect(
          labels(mapper.map(bars([[note(74), note(76, finger: 0), note(74)]]))),
          ['A3', 'E0', 'A3']);
    });

    test('any other number is ignored, and so is 4 off a choice note', () {
      expect(labels(mapper.map(bars([[note(76, finger: 2)]]))), ['E0']);
      expect(labels(mapper.map(bars([[note(71, finger: 4)]]))), ['A1']);
    });

    test('a tied continuation follows the note it holds over', () {
      final p = bars([
        [note(69, finger: 4, tieStart: true)],
        [note(69, tieStop: true), note(69)],
      ]);
      expect(labels(mapper.map(p, preference: ViolinStringPreference.openStrings)),
          ['D4', 'D4', 'A0']);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

NoteEvent _note(NoteValue v, {bool dotted = false, int midi = 69}) =>
    NoteEvent(
      pitch: 'A4',
      midiNumber: midi,
      octave: 4,
      noteValue: v,
      dotted: dotted,
      isRest: false,
    );

NoteEvent _rest(NoteValue v, {bool dotted = false}) => NoteEvent(
      pitch: '',
      midiNumber: 0,
      octave: 4,
      noteValue: v,
      dotted: dotted,
      isRest: true,
    );

ParsedPiece _piece(List<List<NoteEvent>> measureNotes) {
  final measures = measureNotes
      .asMap()
      .entries
      .map((e) => Measure(number: e.key + 1, notes: e.value))
      .toList();
  return ParsedPiece(
    keySignature: 'G',
    keyFifths: 1,
    keyMode: KeyMode.major,
    measures: measures,
  );
}

double _dur(ScheduledNote n) => n.offsetSeconds - n.onsetSeconds;

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late MidiGenerator gen;

  setUp(() {
    // forTest() bypasses asset loading; uses 480 tpb (standard MIDI default).
    gen = MidiGenerator.forTest(ticksPerBeat: 480);
  });

  group('Note durations at 60 BPM (1 quarter note = 1 second)', () {
    const bpm = 60;

    test('whole note = 4 s', () {
      final d = gen.generate(_piece([[_note(NoteValue.whole)]]), bpm);
      expect(_dur(d.notes.single), closeTo(4.0, 0.001));
    });

    test('half note = 2 s', () {
      final d = gen.generate(_piece([[_note(NoteValue.half)]]), bpm);
      expect(_dur(d.notes.single), closeTo(2.0, 0.001));
    });

    test('quarter note = 1 s', () {
      final d = gen.generate(_piece([[_note(NoteValue.quarter)]]), bpm);
      expect(_dur(d.notes.single), closeTo(1.0, 0.001));
    });

    test('eighth note = 0.5 s', () {
      final d = gen.generate(_piece([[_note(NoteValue.eighth)]]), bpm);
      expect(_dur(d.notes.single), closeTo(0.5, 0.001));
    });

    test('sixteenth note = 0.25 s', () {
      final d = gen.generate(_piece([[_note(NoteValue.sixteenth)]]), bpm);
      expect(_dur(d.notes.single), closeTo(0.25, 0.001));
    });
  });

  group('Dotted note durations at 60 BPM', () {
    const bpm = 60;

    test('dotted half = 3 s', () {
      final d =
          gen.generate(_piece([[_note(NoteValue.half, dotted: true)]]), bpm);
      expect(_dur(d.notes.single), closeTo(3.0, 0.001));
    });

    test('dotted quarter = 1.5 s', () {
      final d = gen
          .generate(_piece([[_note(NoteValue.quarter, dotted: true)]]), bpm);
      expect(_dur(d.notes.single), closeTo(1.5, 0.001));
    });

    test('dotted eighth = 0.75 s', () {
      final d =
          gen.generate(_piece([[_note(NoteValue.eighth, dotted: true)]]), bpm);
      expect(_dur(d.notes.single), closeTo(0.75, 0.001));
    });
  });

  group('measureOnsetSeconds accumulation at 60 BPM', () {
    const bpm = 60;

    test('single measure starts at 0', () {
      final d = gen.generate(_piece([[_note(NoteValue.quarter)]]), bpm);
      expect(d.measureOnsetSeconds, [closeTo(0.0, 0.001)]);
    });

    test('second measure (4 quarters each) starts at 4 s', () {
      final bar = List.filled(4, _note(NoteValue.quarter));
      final d = gen.generate(_piece([bar, bar]), bpm);
      expect(d.measureOnsetSeconds[0], closeTo(0.0, 0.001));
      expect(d.measureOnsetSeconds[1], closeTo(4.0, 0.001));
    });

    test('three measures accumulate correctly', () {
      final bar1 = [_note(NoteValue.half), _note(NoteValue.half)]; // 4 s
      final bar2 = [_note(NoteValue.whole)]; // 4 s
      final bar3 = [
        _note(NoteValue.quarter),
        _rest(NoteValue.quarter),
        _note(NoteValue.quarter),
        _note(NoteValue.quarter),
      ]; // 4 s
      final d = gen.generate(_piece([bar1, bar2, bar3]), bpm);
      expect(d.measureOnsetSeconds[0], closeTo(0.0, 0.001));
      expect(d.measureOnsetSeconds[1], closeTo(4.0, 0.001));
      expect(d.measureOnsetSeconds[2], closeTo(8.0, 0.001));
    });

    test('totalDurationSeconds = sum of all note/rest durations', () {
      final bar = [
        _note(NoteValue.quarter),
        _rest(NoteValue.quarter),
        _note(NoteValue.half),
      ];
      final d = gen.generate(_piece([bar]), bpm);
      expect(d.totalDurationSeconds, closeTo(4.0, 0.001));
    });
  });

  group('measureNumbers / indexOfMeasure (pickup mapping)', () {
    // Piece with a pickup (number 0) followed by full bars 1, 2.
    ParsedPiece pickupPiece() => ParsedPiece(
          keySignature: 'G',
          keyFifths: 1,
          keyMode: KeyMode.major,
          measures: [
            Measure(number: 0, notes: [_note(NoteValue.quarter)]), // pickup, 1 s
            Measure(number: 1, notes: List.filled(4, _note(NoteValue.quarter))),
            Measure(number: 2, notes: List.filled(4, _note(NoteValue.quarter))),
          ],
        );

    test('measureNumbers is in document order, pickup first (0)', () {
      final d = gen.generate(pickupPiece(), 60);
      expect(d.measureNumbers, [0, 1, 2]);
    });

    test('indexOfMeasure maps number → array index (not number-1)', () {
      final d = gen.generate(pickupPiece(), 60);
      expect(d.indexOfMeasure(0), 0); // pickup
      expect(d.indexOfMeasure(1), 1); // first full bar lives at index 1
      expect(d.indexOfMeasure(2), 2);
      expect(d.indexOfMeasure(99), -1);
    });

    test('onset of a numbered measure resolves via the index, not number-1', () {
      final d = gen.generate(pickupPiece(), 60);
      // pickup = 1 s, then 4 s bars. Onset of measure number 1 is 1.0 s
      // (NOT measureOnsetSeconds[1-1=0] == 0.0, the old off-by-one).
      expect(d.measureOnsetSeconds[d.indexOfMeasure(1)], closeTo(1.0, 0.001));
      expect(d.measureOnsetSeconds[d.indexOfMeasure(2)], closeTo(5.0, 0.001));
    });
  });

  group('Rests are excluded from notes list but advance cursor', () {
    test('rest produces no ScheduledNote', () {
      final d = gen.generate(_piece([[_rest(NoteValue.whole)]]), 60);
      expect(d.notes, isEmpty);
      expect(d.totalDurationSeconds, closeTo(4.0, 0.001));
    });

    test('note after rest has correct onset', () {
      final d = gen.generate(
          _piece([[_rest(NoteValue.quarter), _note(NoteValue.quarter)]]), 60);
      expect(d.notes.single.onsetSeconds, closeTo(1.0, 0.001));
    });
  });

  group('Tempo scaling', () {
    test('120 BPM quarter note = 0.5 s', () {
      final d = gen.generate(_piece([[_note(NoteValue.quarter)]]), 120);
      expect(_dur(d.notes.single), closeTo(0.5, 0.001));
    });

    test('40 BPM quarter note = 1.5 s', () {
      final d = gen.generate(_piece([[_note(NoteValue.quarter)]]), 40);
      expect(_dur(d.notes.single), closeTo(1.5, 0.001));
    });
  });

  group('MIDI note numbers are preserved', () {
    test('note with midiNumber 60 schedules key 60', () {
      final d =
          gen.generate(_piece([[_note(NoteValue.quarter, midi: 60)]]), 60);
      expect(d.notes.single.midiNote, 60);
    });
  });

  group('Repeats expand the performance order', () {
    // |: m1 m2 :|  — each a 4/4 bar of four quarters (4 s at 60 BPM).
    ParsedPiece repeatPiece() => ParsedPiece(
          keySignature: 'G',
          keyFifths: 1,
          keyMode: KeyMode.major,
          measures: [
            Measure(
                number: 1,
                notes: List.filled(4, _note(NoteValue.quarter)),
                repeatStart: true),
            Measure(
                number: 2,
                notes: List.filled(4, _note(NoteValue.quarter)),
                repeatEnd: true),
          ],
        );

    test('a |: A B :| span plays A B A B', () {
      final d = gen.generate(repeatPiece(), 60);
      expect(d.measureNumbers, [1, 2, 1, 2]);
      expect(d.measureOnsetSeconds[0], closeTo(0.0, 0.001));
      expect(d.measureOnsetSeconds[1], closeTo(4.0, 0.001));
      expect(d.measureOnsetSeconds[2], closeTo(8.0, 0.001));
      expect(d.measureOnsetSeconds[3], closeTo(12.0, 0.001));
      expect(d.totalDurationSeconds, closeTo(16.0, 0.001));
      // 4 measures × 4 notes.
      expect(d.notes.length, 16);
    });

    test('onsets are strictly increasing across the repeat', () {
      final d = gen.generate(repeatPiece(), 60);
      for (var i = 1; i < d.highlightEvents.length; i++) {
        expect(d.highlightEvents[i].onsetSeconds,
            greaterThan(d.highlightEvents[i - 1].onsetSeconds - 1e-9));
      }
    });

    test('replayed measure beatPosition returns to its first-pass value', () {
      final d = gen.generate(repeatPiece(), 60);
      // 4 notes per measure; index 0 = first note of m1 (pass 1),
      // index 8 = first note of m1 (pass 2, the replay).
      final firstPass = d.highlightEvents[0];
      final replay = d.highlightEvents[8];
      expect(replay.measureNumber, 1);
      // Score-anchored beat drops back even though performance time advanced.
      expect(replay.beatPosition, closeTo(firstPass.beatPosition, 1e-9));
      expect(replay.onsetSeconds, closeTo(8.0, 0.001));
      expect(replay.onsetSeconds, greaterThan(firstPass.onsetSeconds));
    });

    test('lastIndexOfMeasure finds the final occurrence', () {
      final d = gen.generate(repeatPiece(), 60);
      expect(d.indexOfMeasure(1), 0);
      expect(d.lastIndexOfMeasure(1), 2);
      expect(d.lastIndexOfMeasure(2), 3);
      expect(d.lastIndexOfMeasure(99), -1);
    });

    test('no repeats → identity order (unchanged behaviour)', () {
      final bar = List.filled(4, _note(NoteValue.quarter));
      final d = gen.generate(_piece([bar, bar]), 60);
      expect(d.measureNumbers, [1, 2]);
      expect(d.notes.length, 8);
    });
  });
}

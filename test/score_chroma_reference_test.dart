import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/score_chroma_reference.dart';

NoteEvent _note(int midi, NoteValue v) => NoteEvent(
      pitch: 'X',
      midiNumber: midi,
      octave: 4,
      noteValue: v,
      dotted: false,
      isRest: false,
    );

void main() {
  late MidiGenerator gen;
  setUp(() => gen = MidiGenerator.forTest(ticksPerBeat: 480));

  ParsedPiece piece(List<List<NoteEvent>> measureNotes) => ParsedPiece(
        keySignature: 'C',
        keyFifths: 0,
        keyMode: KeyMode.major,
        measures: measureNotes
            .asMap()
            .entries
            .map((e) => Measure(number: e.key + 1, notes: e.value))
            .toList(),
      );

  test('a single sustained note fills every frame it spans with its pitch '
      'class, and nothing else', () {
    // 60 BPM, whole note = 4s. C4 = midi 60, pitch class 0.
    final p = piece([
      [_note(60, NoteValue.whole)]
    ]);
    const hop = 0.5;
    final ref = ScoreChromaReferenceBuilder(gen).build(p, 60, hop);

    // 4 seconds / 0.5s hop -> frames covering [0, 4]s should be non-zero at
    // pitch class 0 and zero everywhere else.
    for (final frame in ref.frames) {
      for (var pc = 0; pc < frame.length; pc++) {
        if (pc == 0) {
          expect(frame[pc], greaterThan(0));
        } else {
          expect(frame[pc], 0);
        }
      }
    }
  });

  test('two consecutive different-pitch notes occupy disjoint frame ranges',
      () {
    // 60 BPM: two half notes (2s each), C4 (midi 60, pc 0) then D4 (midi 62, pc 2).
    final p = piece([
      [_note(60, NoteValue.half), _note(62, NoteValue.half)]
    ]);
    const hop = 0.25;
    final ref = ScoreChromaReferenceBuilder(gen).build(p, 60, hop);

    // First note spans [0, 2)s -> frame indices [0, 8); second spans [2, 4)s.
    final earlyFrame = ref.frames[2]; // t = 0.5s, inside the first note
    final lateFrame = ref.frames[10]; // t = 2.5s, inside the second note
    expect(earlyFrame[0], greaterThan(0));
    expect(earlyFrame[2], 0);
    expect(lateFrame[2], greaterThan(0));
    expect(lateFrame[0], 0);
  });

  test('measureOnsetSeconds/measureNumbers pass through from MidiData '
      'unchanged, including repeat expansion', () {
    final p = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      measures: [
        Measure(
            number: 1,
            notes: [_note(60, NoteValue.whole)],
            repeatStart: true),
        Measure(number: 2, notes: [_note(62, NoteValue.whole)], repeatEnd: true),
      ],
    );
    final ref = ScoreChromaReferenceBuilder(gen).build(p, 60, 0.5);
    expect(ref.measureNumbers, [1, 2, 1, 2]);
    expect(ref.measureOnsetSeconds, [0.0, 4.0, 8.0, 12.0]);
  });

  test('frame vectors are L2-normalized', () {
    final p = piece([
      [_note(60, NoteValue.quarter), _note(64, NoteValue.quarter)]
    ]);
    final ref = ScoreChromaReferenceBuilder(gen).build(p, 60, 0.25);
    for (final frame in ref.frames) {
      var sumSq = 0.0;
      for (final v in frame) {
        sumSq += v * v;
      }
      expect(sumSq, anyOf(closeTo(0, 1e-9), closeTo(1, 1e-6)));
    }
  });
}

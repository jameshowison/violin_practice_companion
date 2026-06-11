import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';

NoteEvent _note(NoteValue v, {bool dotted = false}) => NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: v,
      dotted: dotted,
      isRest: false,
    );

void main() {
  test('a full 4/4 measure is not flagged', () {
    final m = Measure(number: 1, notes: [
      _note(NoteValue.quarter),
      _note(NoteValue.quarter),
      _note(NoteValue.quarter),
      _note(NoteValue.quarter),
    ]);
    expect(m.isDurationMismatch(4, 4), isFalse);
  });

  test('a short measure is flagged', () {
    final m = Measure(number: 2, notes: [
      _note(NoteValue.quarter),
      _note(NoteValue.quarter),
      _note(NoteValue.quarter),
    ]);
    expect(m.isDurationMismatch(4, 4), isTrue);
  });

  test('dotted-half + quarter totals a full 4/4 bar', () {
    final m = Measure(number: 3, notes: [
      _note(NoteValue.half, dotted: true),
      _note(NoteValue.quarter),
    ]);
    expect(m.isDurationMismatch(4, 4), isFalse);
  });

  test('pickup measure (number 0) is never flagged', () {
    final m = Measure(number: 0, notes: [_note(NoteValue.quarter)]);
    expect(m.isDurationMismatch(4, 4), isFalse);
  });

  test('flaggedMeasureNumbers collects mismatched bars', () {
    final piece = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      beatsPerMeasure: 4,
      beatType: 4,
      measures: [
        Measure(number: 1, notes: [_note(NoteValue.whole)]), // ok
        Measure(number: 2, notes: [_note(NoteValue.half)]), // short
      ],
    );
    expect(piece.flaggedMeasureNumbers, {2});
  });
}

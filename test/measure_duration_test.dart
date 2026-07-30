import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';

NoteEvent _note(NoteValue v, {bool dotted = false, bool isChord = false}) =>
    NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: v,
      dotted: dotted,
      isRest: false,
      isChord: isChord,
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

  group('chord members add no time to the beat count', () {
    test('four beats where two are one chord is not flagged', () {
      // 4/4: quarter, then a two-note chord on one stem, then two quarters.
      final m = Measure(number: 6, notes: [
        _note(NoteValue.quarter),
        _note(NoteValue.quarter),
        _note(NoteValue.quarter, isChord: true), // stacked on the previous stem
        _note(NoteValue.quarter),
        _note(NoteValue.quarter),
      ]);
      expect(m.actualUnits, 32); // 4 quarters, not 5
      expect(m.isDurationMismatch(4, 4), isFalse);
    });

    test('a three-note chord filling a whole bar is not flagged', () {
      final m = Measure(number: 7, notes: [
        _note(NoteValue.whole),
        _note(NoteValue.whole, isChord: true),
        _note(NoteValue.whole, isChord: true),
      ]);
      expect(m.actualUnits, 32);
      expect(m.isDurationMismatch(4, 4), isFalse);
    });

    test('a genuinely short bar containing a chord is still flagged', () {
      final m = Measure(number: 8, notes: [
        _note(NoteValue.quarter),
        _note(NoteValue.quarter, isChord: true),
        _note(NoteValue.quarter),
      ]);
      expect(m.actualUnits, 16); // 2 beats
      expect(m.isDurationMismatch(4, 4), isTrue);
    });
  });

  test('a short FIRST measure numbered 1 (anacrusis) is NOT flagged', () {
    // OMR output often numbers a pickup "1" instead of 0, so the number==0
    // guard misses it; the first-measure-is-short rule should catch it.
    final piece = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      beatsPerMeasure: 2,
      beatType: 4,
      measures: [
        Measure(number: 1, notes: [_note(NoteValue.eighth)]), // short pickup
        Measure(number: 2, notes: [
          _note(NoteValue.quarter),
          _note(NoteValue.eighth),
          _note(NoteValue.eighth),
        ]), // full 2/4 bar
        Measure(number: 3, notes: [_note(NoteValue.eighth)]), // genuinely short
      ],
    );
    // Measure 1 excluded (pickup); measure 3 still flagged.
    expect(piece.flaggedMeasureNumbers, {3});
  });
}

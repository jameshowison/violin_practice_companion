import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:test/test.dart';

NoteEvent _note(NoteValue value, {bool dotted = false, bool rest = false}) =>
    NoteEvent(
      pitch: rest ? 'R' : 'A',
      midiNumber: rest ? 0 : 69,
      octave: 4,
      noteValue: value,
      dotted: dotted,
      isRest: rest,
      scoreFinger: null,
    );

Measure _bar(List<NoteEvent> notes, {List<NoteEvent> hidden = const []}) =>
    Measure(number: 0, notes: notes, hiddenLeadNotes: hidden);

void main() {
  group('pickupUnitsOf', () {
    test('a full bar is not a pickup', () {
      expect(
          pickupUnitsOf(_bar(List.filled(4, _note(NoteValue.quarter))),
              beatsPerMeasure: 4, beatType: 4),
          0);
    });

    test("Devil's Dream: a lone quarter in 4/4 is one beat", () {
      expect(
          pickupUnitsOf(_bar([_note(NoteValue.quarter)]),
              beatsPerMeasure: 4, beatType: 4),
          8);
    });

    test('hidden lead rests count towards the pickup', () {
      // The Happy Farmer's anacrusis: a hidden eighth rest then a sounding
      // eighth. Half a beat sounds, but the pickup owns a whole beat of the bar
      // and the audio clock starts at the barline.
      expect(
          pickupUnitsOf(
              _bar([_note(NoteValue.eighth)],
                  hidden: [_note(NoteValue.eighth, rest: true)]),
              beatsPerMeasure: 4,
              beatType: 4),
          8);
      // Without the hidden rest the same bar is only half a beat.
      expect(
          pickupUnitsOf(_bar([_note(NoteValue.eighth)]),
              beatsPerMeasure: 4, beatType: 4),
          4);
    });

    test('a start part-way into a full bar is a pickup of what is left', () {
      // A section starting on its lead-in: the last two eighths of 4/4.
      final bar = _bar([
        _note(NoteValue.half),
        _note(NoteValue.quarter),
        _note(NoteValue.eighth),
        _note(NoteValue.eighth),
      ]);
      expect(pickupUnitsOf(bar, beatsPerMeasure: 4, beatType: 4, fromNote: 2),
          8);
      expect(pickupUnitsOf(bar, beatsPerMeasure: 4, beatType: 4, fromNote: 0),
          0);
    });

    test('null (no such measure) is no pickup', () {
      expect(pickupUnitsOf(null, beatsPerMeasure: 4, beatType: 4), 0);
    });
  });
}

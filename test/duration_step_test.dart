import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/duration_step.dart';
import 'package:violin_practice_companion/models/note_event.dart';

void main() {
  test('ordered list is shortest → longest, 10 entries', () {
    expect(DurationStep.ordered.length, 10);
    expect(DurationStep.ordered.first, const DurationStep(NoteValue.sixteenth, false));
    expect(DurationStep.ordered.last, const DurationStep(NoteValue.whole, true));
  });

  test('next interleaves dot then value', () {
    expect(DurationStep.next(NoteValue.quarter, false),
        const DurationStep(NoteValue.quarter, true));
    expect(DurationStep.next(NoteValue.quarter, true),
        const DurationStep(NoteValue.half, false));
  });

  test('previous walks back down', () {
    expect(DurationStep.previous(NoteValue.quarter, false),
        const DurationStep(NoteValue.eighth, true));
  });

  test('clamps at both ends instead of wrapping', () {
    expect(DurationStep.previous(NoteValue.sixteenth, false),
        const DurationStep(NoteValue.sixteenth, false));
    expect(DurationStep.next(NoteValue.whole, true),
        const DurationStep(NoteValue.whole, true));
  });

  test('thirtySecondUnits are integer-exact including dotted', () {
    expect(thirtySecondUnits(NoteValue.whole, false), 32);
    expect(thirtySecondUnits(NoteValue.quarter, false), 8);
    expect(thirtySecondUnits(NoteValue.quarter, true), 12);
    expect(thirtySecondUnits(NoteValue.sixteenth, false), 2);
    expect(thirtySecondUnits(NoteValue.sixteenth, true), 3);
  });
}

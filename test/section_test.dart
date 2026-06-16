import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/section.dart';

NoteEvent _n() => const NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: false,
    );

// A measure with [count] quarter notes, numbered [number].
Measure _m(int number, {int count = 4}) =>
    Measure(number: number, notes: [for (var i = 0; i < count; i++) _n()]);

void main() {
  group('Section JSON', () {
    test('round-trips label/startMeasure/startNote', () {
      const s = Section(label: 'B', startMeasure: 9, startNote: 2);
      expect(Section.fromJson(s.toJson()), s);
    });

    test('reads new shape with default startNote = 0', () {
      final s = Section.fromJson({'label': 'A', 'startMeasure': 1});
      expect(s.startNote, 0);
      expect(s.label, 'A');
    });

    test('tolerates the legacy endMeasure key (ignored)', () {
      final s = Section.fromJson(
          {'label': 'A', 'startMeasure': 1, 'endMeasure': 8});
      expect(s, const Section(label: 'A', startMeasure: 1, startNote: 0));
    });
  });

  group('resolveSectionRanges', () {
    final measures = [for (var i = 1; i <= 16; i++) _m(i)];

    test('contiguous ranges; last runs to the end', () {
      const starts = [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 9),
      ];
      final r = resolveSectionRanges(starts, measures);
      expect(r.length, 2);
      expect(r[0].label, 'A');
      expect(r[0].startMeasure, 1);
      expect(r[0].endMeasure, 8); // ends the measure before B
      expect(r[0].endNote, -1); // whole measure
      expect(r[1].label, 'B');
      expect(r[1].startMeasure, 9);
      expect(r[1].endMeasure, 16); // to end of piece
      expect(r[1].endNote, -1);
    });

    test('an unmarked leading pickup is covered by no range', () {
      final ms = [_m(0, count: 1), for (var i = 1; i <= 8; i++) _m(i)];
      const starts = [Section(label: 'A', startMeasure: 1)];
      final r = resolveSectionRanges(starts, ms);
      expect(r.single.startMeasure, 1); // pickup (0) is not in any range
    });

    test('mid-measure boundary: shared measure with note edges', () {
      const starts = [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 8, startNote: 2), // pickup inside m8
      ];
      final r = resolveSectionRanges(starts, measures);
      expect(r[0].endMeasure, 8); // shares measure 8
      expect(r[0].endNote, 2); // A ends just before m8's note 2
      expect(r[1].startMeasure, 8);
      expect(r[1].startNote, 2); // B starts mid-measure
    });
  });

  group('sectionLabelByMeasure', () {
    test('labels measures measure-granularly; pre-section measures omitted', () {
      final ms = [_m(0, count: 1), for (var i = 1; i <= 4; i++) _m(i)];
      const starts = [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 3),
      ];
      final map = sectionLabelByMeasure(starts, ms);
      expect(map.containsKey(0), isFalse); // unmarked pickup
      expect(map[1], 'A');
      expect(map[2], 'A');
      expect(map[3], 'B');
      expect(map[4], 'B');
    });
  });
}

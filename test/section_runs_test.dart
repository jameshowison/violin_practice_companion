import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/piece_layout.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';

NoteEvent _n() => const NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: false,
    );

Measure _m(int number, {bool repeatStart = false, bool repeatEnd = false}) =>
    Measure(
      number: number,
      notes: [_n()],
      repeatStart: repeatStart,
      repeatEnd: repeatEnd,
    );

void main() {
  group('sectionRuns (unfolded minimap model)', () {
    test('literal ABAA restatement → A A B with passes, identity perf spans', () {
      final measures = [for (var i = 1; i <= 20; i++) _m(i)];
      const starts = [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 9),
        Section(label: 'A', startMeasure: 17),
      ];
      final runs = sectionRuns(measures, starts);
      expect(runs.map((r) => r.label).toList(), ['A', 'B', 'A']);
      expect(runs[0].passIndex, 0);
      expect(runs[0].passCount, 2); // two A occurrences
      expect(runs[2].passIndex, 1);
      // No repeats → performance order is identity.
      expect((runs[0].perfStart, runs[0].perfEnd), (0, 8));
      expect((runs[1].perfStart, runs[1].perfEnd), (8, 16));
      expect((runs[2].perfStart, runs[2].perfEnd), (16, 20));
    });

    test('a |: A :| repeat yields two A runs in performance order', () {
      // m1, m2(repeat back to start) → performance order [0,1,0,1].
      final measures = [_m(1), _m(2, repeatEnd: true)];
      const starts = [Section(label: 'A', startMeasure: 1)];
      final runs = sectionRuns(measures, starts);
      expect(runs.map((r) => r.label).toList(), ['A', 'A']);
      expect(runs.map((r) => r.passCount).toList(), [2, 2]);
      expect((runs[0].perfStart, runs[0].perfEnd), (0, 2));
      expect((runs[1].perfStart, runs[1].perfEnd), (2, 4));
      // The second pass's slice follows the first — pass-accurate highlighting.
      expect(runs[1].containsPerf(2), isTrue);
      expect(runs[0].containsPerf(2), isFalse);
    });

    test('an unmarked pickup attaches to the following section', () {
      final measures = [
        Measure(number: 0, notes: [_n()]),
        for (var i = 1; i <= 4; i++) _m(i),
      ];
      const starts = [Section(label: 'A', startMeasure: 1)];
      final runs = sectionRuns(measures, starts);
      expect(runs.single.label, 'A');
      expect(runs.single.perfStart, 0); // includes the pickup slot
      expect(runs.single.firstMeasure, 1); // first real measure
    });
  });

  group('HighlightEvent.performanceIndex', () {
    test('is the performance-order ordinal and advances across a repeat', () {
      final piece = ParsedPiece(
        keySignature: 'C',
        keyFifths: 0,
        keyMode: KeyMode.major,
        measures: [_m(1), _m(2, repeatEnd: true)],
      );
      final data = MidiGenerator.forTest().generate(piece, 60);
      // Each measure has one note → 4 events for order [0,1,0,1].
      expect(data.highlightEvents.map((e) => e.performanceIndex).toList(),
          [0, 1, 2, 3]);
      // Measure 1 plays at performance index 0 (first pass) and 2 (second pass).
      final m1 = data.highlightEvents
          .where((e) => e.measureNumber == 1)
          .map((e) => e.performanceIndex)
          .toList();
      expect(m1, [0, 2]);
    });
  });
}

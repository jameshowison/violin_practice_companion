import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/section_detector.dart';

NoteEvent _note(int midi) => NoteEvent(
      pitch: 'X',
      midiNumber: midi,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: false,
    );

Measure _measure(
  int number,
  List<int> midis, {
  bool repeatStart = false,
  bool repeatEnd = false,
  String? partLabel,
}) =>
    Measure(
      number: number,
      notes: [for (final m in midis) _note(m)],
      repeatStart: repeatStart,
      repeatEnd: repeatEnd,
      partLabel: partLabel,
    );

void main() {
  group('authored part labels (e.g. ABC [P:X] markers)', () {
    test('trusted directly, no fingerprint guessing, when there are >= 2', () {
      final measures = [
        _measure(1, [60], partLabel: 'A'),
        _measure(2, [60]),
        _measure(3, [62], partLabel: 'B'),
        _measure(4, [62]),
      ];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => s.label).toList(), ['A', 'B']);
      expect(sections.map((s) => s.startMeasure).toList(), [1, 3]);
    });

    test('a single label is not "complete" — falls through to heuristics', () {
      // Only one marker, no repeat brackets, and a length the block
      // heuristic can't tile: zero sections, same as an unstructured tune —
      // not one lonely, unusable marker.
      final measures = [
        _measure(1, [60], partLabel: 'A'),
        _measure(2, [61]),
        _measure(3, [62]),
      ];
      expect(SectionDetector.detect(measures), isEmpty);
    });

    test('wins over repeat brackets when both are present', () {
      final measures = [
        _measure(1, [60], partLabel: 'A', repeatStart: true),
        _measure(2, [60], repeatEnd: true),
        _measure(3, [62], partLabel: 'B'),
        _measure(4, [62]),
      ];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => s.label).toList(), ['A', 'B']);
      expect(sections.map((s) => s.startMeasure).toList(), [1, 3]);
    });

    test(
        'a marker on a pickup before |: is anchored to the repeat start, '
        'not the pickup', () {
      // Galopede's shape in miniature: [P:A] lands on the pickup (measure 1),
      // the actual |: is on measure 2. Anchoring on the pickup would hide the
      // repeat from sectionRuns (a pickup is never revisited in performance
      // order), collapsing what should be two A passes into one.
      final measures = [
        _measure(1, [59], partLabel: 'A'), // pickup, no repeat flags
        _measure(2, [60], repeatStart: true),
        _measure(3, [61], repeatEnd: true),
        _measure(4, [62], partLabel: 'B'),
      ];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => s.label).toList(), ['A', 'B']);
      expect(sections.map((s) => s.startMeasure).toList(), [2, 4]);
    });

    test('a marker with no repeat before the next one stays on its own measure',
        () {
      final measures = [
        _measure(1, [59], partLabel: 'A'),
        _measure(2, [60]),
        _measure(3, [61], partLabel: 'B'),
        _measure(4, [62]),
      ];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => s.startMeasure).toList(), [1, 3]);
    });
  });

  group('repeat brackets + straight-through tail (no authored labels)', () {
    Measure distinct(int number, {bool repeatStart = false, bool repeatEnd = false}) =>
        _measure(number, [60 + number],
            repeatStart: repeatStart, repeatEnd: repeatEnd);

    test(
        'a repeated 4-bar A followed by an 8-bar B and a 4-bar C tiles as A,B,C',
        () {
      // Mirrors Galopede's real shape: A repeats via |: :|, B and C are
      // straight through with no brackets of their own (8 then 4 bars).
      final measures = [
        for (var i = 1; i <= 4; i++)
          distinct(i, repeatStart: i == 1, repeatEnd: i == 4),
        for (var i = 5; i <= 16; i++) distinct(i), // 12-bar straight tail
      ];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => s.startMeasure).toList(), [1, 5, 13]);
      // The two tail chunks (8 bars, 4 bars) don't fingerprint-match the A
      // strain or each other, so all three get distinct labels.
      expect(sections.map((s) => s.label).toSet().length, 3);
    });

    test('a tail that cannot be tiled by 8s and 4s is dropped, not misplaced',
        () {
      final measures = [
        for (var i = 1; i <= 4; i++)
          distinct(i, repeatStart: i == 1, repeatEnd: i == 4),
        for (var i = 5; i <= 7; i++) distinct(i), // 3-bar tail: no valid tiling
      ];
      // Only the bracketed A strain would remain — below _minStrains, so this
      // yields no sections at all, same as the "no signal, don't guess"
      // behavior for any other unstructured tune.
      expect(SectionDetector.detect(measures), isEmpty);
    });

    test('a tail that tiles into a single 8-bar chunk still counts', () {
      final measures = [
        for (var i = 1; i <= 4; i++)
          distinct(i, repeatStart: i == 1, repeatEnd: i == 4),
        for (var i = 5; i <= 12; i++) distinct(i), // 8-bar tail, one chunk
      ];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => s.startMeasure).toList(), [1, 5]);
    });
  });

  group('regression: no authored labels and no repeat brackets is unchanged',
      () {
    Measure distinct(int number) => _measure(number, [60 + number]);

    test('a clean 32-bar tune still segments into four 8-bar strains', () {
      final measures = [for (var i = 1; i <= 32; i++) distinct(i)];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => s.startMeasure).toList(), [1, 9, 17, 25]);
    });

    test('too few measures yields no sections', () {
      expect(SectionDetector.detect([distinct(1)]), isEmpty);
    });

    test('an unstructured length (not a clean multiple of 8 or 4) yields none',
        () {
      final measures = [for (var i = 1; i <= 5; i++) distinct(i)];
      expect(SectionDetector.detect(measures), isEmpty);
    });
  });

  group('regression: two independent |: :| pairs (e.g. AABB) is unchanged',
      () {
    test('each repeat-bracketed strain becomes its own section', () {
      final measures = [
        _measure(1, [61], repeatStart: true),
        _measure(2, [61], repeatEnd: true),
        _measure(3, [62], repeatStart: true),
        _measure(4, [62], repeatEnd: true),
      ];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => s.startMeasure).toList(), [1, 3]);
      expect(sections.map((s) => s.label).toList(), ['A', 'B']);
    });
  });
}

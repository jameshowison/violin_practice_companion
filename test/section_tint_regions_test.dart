import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/models/section_palette.dart';

NoteEvent _n() => const NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: false,
    );

Measure _m(int number, {int count = 4}) =>
    Measure(number: number, notes: [for (var i = 0; i < count; i++) _n()]);

void main() {
  group('sectionTintRegions (folded staff)', () {
    final measures = [for (var i = 1; i <= 4; i++) _m(i)];
    final measureNumbers = [for (final m in measures) m.number];

    test('A/B yield exactly two colors over the folded score', () {
      const starts = [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 3),
      ];
      final colors = SectionPalette.colorsForSections(starts);
      final regions =
          sectionTintRegions(measureNumbers, starts, colors, measures);
      expect(regions.length, 2);
      expect(regions.map((r) => r.color).toSet().length, 2);
      // A covers engraved indices 0..1 (whole), B covers 2..3 (whole).
      expect(regions[0].startMeasureIndex, 0);
      expect(regions[0].endMeasureIndex, 1);
      expect(regions[0].endNote, -1);
      expect(regions[1].startMeasureIndex, 2);
      expect(regions[1].endMeasureIndex, 3);
    });

    test('a same-label restatement shares one color', () {
      const starts = [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 2),
        Section(label: 'A', startMeasure: 3),
      ];
      final colors = SectionPalette.colorsForSections(starts);
      final regions =
          sectionTintRegions(measureNumbers, starts, colors, measures);
      expect(regions.length, 3);
      expect(regions[0].color, regions[2].color); // both A
      expect(regions[0].color, isNot(regions[1].color)); // A ≠ B
    });

    test('a mid-measure start carries note-level edges', () {
      const starts = [
        Section(label: 'A', startMeasure: 1),
        Section(label: 'B', startMeasure: 2, startNote: 2),
      ];
      final colors = SectionPalette.colorsForSections(starts);
      final regions =
          sectionTintRegions(measureNumbers, starts, colors, measures);
      // A ends mid-measure 2 (engraved index 1), just before note 2.
      expect(regions[0].endMeasureIndex, 1);
      expect(regions[0].endNote, 2);
      // B begins mid-measure 2 at note 2.
      expect(regions[1].startMeasureIndex, 1);
      expect(regions[1].startNote, 2);
    });
  });
}

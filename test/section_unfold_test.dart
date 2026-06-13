import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/piece_layout.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/models/section_palette.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/section_unfold_xml.dart';
import 'package:xml/xml.dart';

Measure _m(int number, {bool repeatStart = false, bool repeatEnd = false}) =>
    Measure(
      number: number,
      notes: const [
        NoteEvent(
          pitch: 'A4',
          midiNumber: 69,
          octave: 4,
          noteValue: NoteValue.quarter,
          dotted: false,
          isRest: false,
          scoreFinger: null,
        ),
      ],
      hiddenLeadNotes: const [],
      repeatStart: repeatStart,
      repeatEnd: repeatEnd,
    );

List<int> _numbers(PieceLayout l) =>
    l.rows.expand((r) => r.map((m) => m.number)).toList();

void main() {
  group('performanceOrder', () {
    test('no repeats → identity', () {
      final ms = [_m(1), _m(2), _m(3)];
      expect(ParsedPiece.performanceOrder(ms), [0, 1, 2]);
    });

    test('backward repeat with no forward returns to start (A A)', () {
      // Mirrors abc_15 section A: |..A..:| with no explicit forward repeat.
      final ms = [_m(1), _m(2), _m(3, repeatEnd: true), _m(4)];
      expect(ParsedPiece.performanceOrder(ms), [0, 1, 2, 0, 1, 2, 3]);
    });

    test('forward + backward repeat replays the span once', () {
      final ms = [
        _m(1),
        _m(2, repeatStart: true),
        _m(3, repeatEnd: true),
        _m(4),
      ];
      expect(ParsedPiece.performanceOrder(ms), [0, 1, 2, 1, 2, 3]);
    });
  });

  group('PieceLayout.computeSectioned', () {
    test('breaks at each section start, wraps long sections', () {
      final ms = [for (var n = 1; n <= 16; n++) _m(n)];
      const sections = [
        Section(label: 'A', startMeasure: 1, endMeasure: 8),
        Section(label: 'B', startMeasure: 9, endMeasure: 16),
      ];
      final layout =
          PieceLayout.computeSectioned(ms, sections, measuresPerRow: 4);
      // A → two sub-rows of 4; B → two sub-rows of 4. A new row always begins
      // a section, so rows 0 and 2 start at the section heads.
      expect(layout.rows.map((r) => r.first.number), [1, 5, 9, 13]);
      expect(layout.rows.map((r) => r.length), [4, 4, 4, 4]);
    });

    test('unfolds a repeated section into two runs (A A)', () {
      // Section A = measures 1-4 with a backward repeat on m4.
      final ms = [_m(1), _m(2), _m(3), _m(4, repeatEnd: true)];
      const sections = [Section(label: 'A', startMeasure: 1, endMeasure: 4)];
      final layout =
          PieceLayout.computeSectioned(ms, sections, measuresPerRow: 4);
      expect(_numbers(layout), [1, 2, 3, 4, 1, 2, 3, 4]);
      // Two A runs → two rows, the second beginning a fresh section.
      expect(layout.rows.length, 2);
      expect(layout.rows.map((r) => r.first.number), [1, 1]);
      // Repeats are unfolded, so no copy carries a repeat barline flag (the
      // jianpu/fingering views must not draw `|:`/`:|` glyphs in ABAA mode).
      final all = layout.rows.expand((r) => r);
      expect(all.any((m) => m.repeatStart || m.repeatEnd), isFalse);
    });

    test('keeps a pickup attached to the first section', () {
      final ms = [_m(0), _m(1), _m(2)];
      const sections = [Section(label: 'A', startMeasure: 1, endMeasure: 2)];
      final layout =
          PieceLayout.computeSectioned(ms, sections, measuresPerRow: 4);
      // Pickup (m0) is not split onto its own row before section A.
      expect(layout.rows.length, 1);
      expect(_numbers(layout), [0, 1, 2]);
    });
  });

  group('PieceLayout.runs', () {
    test('folded layout carries no runs (section apparatus is ABAA-only)', () {
      final ms = [for (var n = 1; n <= 16; n++) _m(n)];
      const sections = [
        Section(label: 'A', startMeasure: 1, endMeasure: 8),
        Section(label: 'B', startMeasure: 9, endMeasure: 16),
      ];
      expect(PieceLayout.compute(ms, sections, measuresPerRow: 4).runs,
          isEmpty);
    });

    test('ABAA: repeated section yields numbered passes', () {
      final ms = [_m(1), _m(2), _m(3), _m(4, repeatEnd: true)];
      const sections = [Section(label: 'A', startMeasure: 1, endMeasure: 4)];
      final runs =
          PieceLayout.computeSectioned(ms, sections, measuresPerRow: 4).runs;
      expect(runs.map((r) => r.title), ['A (1 of 2)', 'A (2 of 2)']);
      expect(runs.map((r) => r.rowStart), [0, 1]);
      expect(runs.every((r) => r.rowCount == 1), isTrue);
    });

    test('ABAA gossec fixture: A A B C C D D run titles', () {
      final xml = File('assets/fixtures/gossec_gavotte.xml').readAsStringSync();
      const sections = [
        Section(label: 'A', startMeasure: 1, endMeasure: 8),
        Section(label: 'B', startMeasure: 9, endMeasure: 16),
        Section(label: 'C', startMeasure: 17, endMeasure: 24),
        Section(label: 'D', startMeasure: 25, endMeasure: 32),
      ];
      final parsed = MusicXmlParser().parse(xml);
      final layout =
          PieceLayout.computeSectioned(parsed.measures, sections, measuresPerRow: 4);
      expect(layout.runs.map((r) => r.label), ['A', 'A', 'B', 'C', 'C', 'D', 'D']);
      expect(layout.runs.map((r) => r.title), [
        'A (1 of 2)', 'A (2 of 2)', 'B', 'C (1 of 2)', 'C (2 of 2)',
        'D (1 of 2)', 'D (2 of 2)',
      ]);
      // Row spans tile the layout with no gaps/overlaps.
      var expectedStart = 0;
      for (final r in layout.runs) {
        expect(r.rowStart, expectedStart);
        expectedStart += r.rowCount;
      }
      expect(expectedStart, layout.rows.length);
    });
  });

  group('sectionTintSpans', () {
    const sections = [
      Section(label: 'A', startMeasure: 1, endMeasure: 8),
      Section(label: 'B', startMeasure: 9, endMeasure: 16),
    ];
    final colors = SectionPalette.colorsForSections(sections);

    test('folded order → one contiguous span per section', () {
      final nums = [for (var n = 1; n <= 16; n++) n];
      final spans = sectionTintSpans(nums, sections, colors);
      expect(spans.map((s) => '${s.start}-${s.end}'), ['0-7', '8-15']);
      expect(spans[0].color, SectionPalette.hex(colors['A']!));
      expect(spans[1].color, SectionPalette.hex(colors['B']!));
    });

    test('unfolded A A merges into one A-colored span; pickup untinted', () {
      // pickup(0) then A(1-8) twice. Both copies share label A, so the wash is
      // one continuous span (the system break + minimap mark the passes).
      final nums = [0, ...[for (var n = 1; n <= 8; n++) n], ...[for (var n = 1; n <= 8; n++) n]];
      final spans = sectionTintSpans(nums, sections, colors);
      // Index 0 (pickup) has no section → span starts at 1, runs to 16.
      expect(spans.length, 1);
      expect('${spans.first.start}-${spans.first.end}', '1-16');
      expect(spans.first.color, SectionPalette.hex(colors['A']!));
    });
  });

  group('SectionUnfoldXml', () {
    const xml = '''
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>v</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes><divisions>1</divisions></attributes>
      <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
    </measure>
    <measure number="2">
      <note><pitch><step>B</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
      <barline location="right">
        <bar-style>light-heavy</bar-style>
        <repeat direction="backward"/>
      </barline>
    </measure>
  </part>
</score-partwise>''';

    test('duplicates measures, strips repeats, injects a system break', () {
      final parsed = MusicXmlParser().parse(xml);
      const sections = [Section(label: 'A', startMeasure: 1, endMeasure: 2)];
      final out = SectionUnfoldXml.apply(xml, parsed.measures, sections);
      final doc = XmlDocument.parse(out);

      final measureEls = doc.findAllElements('measure').toList();
      expect(measureEls.length, 4, reason: 'A repeated → A A = 4 measures');

      // Repeat barlines are gone.
      expect(doc.findAllElements('repeat'), isEmpty);

      // Emitted measures are renumbered sequentially (no duplicate numbers).
      expect(measureEls.map((e) => e.getAttribute('number')),
          ['1', '2', '3', '4']);

      // Exactly one new-system print, on the start of the second A run (3rd
      // emitted measure = positional index 2).
      final prints = doc.findAllElements('print').toList();
      expect(prints.length, 1);
      expect(prints.first.getAttribute('new-system'), 'yes');
      expect(measureEls[2].findElements('print').isNotEmpty, isTrue);
    });

    test('is a no-op when there are no repeats and no sections', () {
      const plain = '''
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>v</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes><divisions>1</divisions></attributes>
      <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
    </measure>
  </part>
</score-partwise>''';
      final parsed = MusicXmlParser().parse(plain);
      final out = SectionUnfoldXml.apply(plain, parsed.measures, const []);
      expect(out, plain);
    });
  });
}

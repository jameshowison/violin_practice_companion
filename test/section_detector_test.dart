import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/piece_layout.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
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

  group('lead-ins (4/4, an opening pickup, 8-bar strains)', () {
    NoteEvent n(NoteValue v, {int midi = 60, bool rest = false, bool tieStop = false}) =>
        NoteEvent(
          pitch: rest ? 'R' : 'X',
          midiNumber: rest ? 0 : midi,
          octave: 4,
          noteValue: v,
          dotted: false,
          isRest: rest,
          tieStop: tieStop,
        );
    const q = NoteValue.quarter, h = NoteValue.half, e = NoteValue.eighth;

    // Bar 1 is the pickup; bars 2–9 and 10–17 are two strains (B at 10), and
    // [bar9] is the bar the B strain's lead-in comes out of.
    List<Measure> tune(List<NoteEvent> pickup, List<NoteEvent> bar9) => [
          Measure(number: 1, notes: pickup),
          for (var b = 2; b <= 8; b++)
            Measure(number: b, notes: [for (var i = 0; i < 4; i++) n(q, midi: 60 + b)]),
          Measure(number: 9, notes: bar9),
          for (var b = 10; b <= 17; b++)
            Measure(number: b, notes: [for (var i = 0; i < 4; i++) n(q, midi: 80 + b)]),
        ];
    String starts(List<Measure> measures) => SectionDetector.detect(measures)
        .map((s) => '${s.startMeasure}:${s.startNote}')
        .join(' ');

    // A three-beat pickup, so the pickup-length tail differs from the
    // phrase-end answer in each of these.
    final threeBeats = [n(q), n(q), n(q)];

    test('starts after a long note, even when shorter than the pickup', () {
      // A three-beat tail would end mid-way through the half note.
      expect(starts(tune(threeBeats, [n(h), n(q), n(e), n(e)])), '1:0 9:1');
    });

    test('starts after a note held over from the bar before', () {
      // A three-beat tail would give 9:1.
      expect(
          starts(tune(threeBeats, [n(q), n(q, tieStop: true), n(q), n(q)])),
          '1:0 9:2');
    });

    test('a bar that ends on a rest or a long note has no lead-in', () {
      expect(starts(tune([n(h)], [n(h), n(e), n(e), n(q, rest: true)])),
          '1:0 10:0');
      expect(starts(tune([n(q)], [n(q), n(q), n(h)])), '1:0 10:0');
    });

    test('starts after a rest, skipping it', () {
      expect(starts(tune([n(q)], [n(q), n(q), n(q, rest: true), n(q)])),
          '1:0 9:3');
    });

    test('falls back to the pickup length with no phrase end', () {
      expect(starts(tune([n(q)], [n(q), n(q), n(q), n(q)])), '1:0 9:3');
    });

    test('a lead-in is never longer than the pickup', () {
      // After the held note, three quarters follow; the pickup is one.
      expect(starts(tune([n(q)], [n(q, tieStop: true), n(q), n(q), n(q)])),
          '1:0 9:3');
    });

    test('no opening pickup, no lead-ins', () {
      final measures = tune([n(q)], [n(h), n(q), n(q)]).sublist(1);
      expect(starts(measures), '2:0 10:0');
    });
  });

  group('authored ABC lines', () {
    Measure bar(int number, List<int> midis, {int? line}) => Measure(
          number: number,
          notes: [for (final m in midis) _note(m)],
          lineStartNote: line,
        );

    test('each line is a strain, starting mid-bar where the line does', () {
      // Lines of 4 bars, the second beginning on the last beat of bar 4.
      final measures = [
        bar(1, [60, 61, 62, 63]),
        bar(2, [60, 61, 62, 63]),
        bar(3, [60, 61, 62, 63]),
        bar(4, [60, 61, 62, 70], line: 3),
        bar(5, [71, 72, 73, 74]),
        bar(6, [71, 72, 73, 74]),
        bar(7, [71, 72, 73, 74]),
      ];
      final sections = SectionDetector.detect(measures);
      expect(sections.map((s) => '${s.label}@${s.startMeasure}:${s.startNote}'),
          ['A@1:0', 'B@4:3']);
    });

    test('ignored when a line is shorter than two bars', () {
      final measures = [
        bar(1, [60, 61, 62, 63]),
        bar(2, [64, 65, 66, 67], line: 0),
        bar(3, [68, 69, 70, 71], line: 0),
      ];
      expect(SectionDetector.detect(measures), isEmpty);
    });

    test('ignored when the marker has drifted past the bar\'s notes', () {
      final measures = [
        bar(1, [60, 61]),
        bar(2, [60, 61]),
        bar(3, [62, 63], line: 2),
        bar(4, [62, 63]),
      ];
      expect(SectionDetector.detect(measures), isEmpty);
    });
  });

  test('a part label placed mid-bar starts its section on that note', () {
    final measures = [
      _measure(1, [60, 61], partLabel: 'A'),
      _measure(2, [60, 61]),
      Measure(
          number: 3,
          notes: [_note(60), _note(62)],
          partLabel: 'B',
          partLabelNote: 1),
      _measure(4, [62, 63]),
    ];
    final sections = SectionDetector.detect(measures);
    expect(sections.map((s) => '${s.label}@${s.startMeasure}:${s.startNote}'),
        ['A@1:0', 'B@3:1']);
  });

  group('converted ABC fixtures', () {
    String detect(String name) => SectionDetector.detect(MusicXmlParser()
            .parse(File('test/fixtures/$name.musicxml').readAsStringSync())
            .measures)
        .map((s) => '${s.label}@${s.startMeasure}:${s.startNote}')
        .join(' ');

    test('the parser reads where each authored line and part begins', () {
      Map<int, int> lines(String name) => {
            for (final m in MusicXmlParser()
                .parse(File('test/fixtures/$name.musicxml').readAsStringSync())
                .measures)
              if (m.lineStartNote != null) m.number: m.lineStartNote!,
          };
      expect(lines('amazing_grace'), {5: 1, 9: 1, 13: 1});
      expect(lines('gundagai_lyrics'), {10: 0, 18: 0, 26: 0});
      final c = MusicXmlParser()
          .parse(File('test/fixtures/galopede.musicxml').readAsStringSync())
          .measures
          .firstWhere((m) => m.partLabel == 'C');
      expect((c.number, c.partLabelNote), (13, 2));
    });

    test('re-detection borrows the hints of a fresh conversion, bar for bar',
        () {
      List<Measure> parse(String xml) => MusicXmlParser().parse(xml).measures;
      final fresh =
          File('test/fixtures/amazing_grace.musicxml').readAsStringSync();
      // An import from before line starts were kept: no hints in the XML.
      final old = parse(fresh.replaceAll(
          '<direction><direction-type><other-direction>abc-line'
              '</other-direction></direction-type></direction>',
          ''));
      expect(old.any((m) => m.lineStartNote != null), isFalse);
      final merged = SectionDetector.withAuthoredHints(old, parse(fresh));
      expect(SectionDetector.detect(merged).map((s) => s.startNote),
          [0, 1, 1, 1]);
      // A bar edited since (a note fewer) means the positions can't be trusted.
      final edited = [...old]
        ..[4] = old[4].copyWithNotes(old[4].notes.sublist(1));
      expect(SectionDetector.withAuthoredHints(edited, parse(fresh)),
          same(edited));
    });

    test('Amazing Grace: each line begins on its lead-in, mid-bar', () {
      expect(detect('amazing_grace'), 'A@1:0 B@5:1 C@9:1 A@13:1');
    });

    test("Devil's Dream: starts at repeats stay on the downbeat (plan §1.3)",
        () {
      expect(detect('devils_dream'), 'A@1:0 B@10:0');
    });

    test("Devil's Dream: A starts on its pickup and still plays twice", () {
      final measures = MusicXmlParser()
          .parse(File('test/fixtures/devils_dream.musicxml').readAsStringSync())
          .measures;
      final runs = sectionRuns(measures, SectionDetector.detect(measures));
      expect([for (final r in runs) '${r.label}${r.passIndex}'],
          ['A0', 'A1', 'B0', 'B1']);
      expect(runs.first.firstMeasure, 1);
      expect(runs[1].firstMeasure, 2); // the replay starts on the `|:`
    });
  });
}

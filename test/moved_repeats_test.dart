import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:violin_practice_companion/models/engraved_measure_map.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/section_detector.dart';
import 'package:violin_practice_companion/services/system_break_injector.dart';

/// Devil's Dream, `e2 |: … A2 e2 :| |: ceAe …`: in a section layout, B's
/// line opens on bar 9's `e2`, so A's repeat moves to include its pickup.
void main() {
  final xml = File('test/fixtures/devils_dream.musicxml').readAsStringSync();
  final measures = MusicXmlParser().parse(xml).measures;
  final sections = SectionDetector.detect(measures);

  List<MovedRepeat> moved(String fixture) {
    final m = MusicXmlParser()
        .parse(File('test/fixtures/$fixture.musicxml').readAsStringSync())
        .measures;
    return movedRepeats(SectionDetector.detect(m), m);
  }

  test('one moved repeat: close 9 at its e2, |: 2 moves onto the pickup', () {
    expect(movedRepeats(sections, measures), [
      (closeMeasure: 9, tailNote: 5, openMeasure: 2, leadInMeasure: 1),
    ]);
  });

  test("Galopede's `d c |: … A4 A2 dc :|` is the same shape", () {
    expect(moved('galopede'), [
      (closeMeasure: 5, tailNote: 2, openMeasure: 2, leadInMeasure: 1),
    ]);
  });

  test('none where no split tail repeats a lead-in', () {
    for (final name in [
      'amazing_grace',
      'circle',
      'gundagai',
      'gundagai_lyrics',
      'old_joe_clark',
    ]) {
      expect(moved(name), isEmpty, reason: name);
    }
  });

  test('a tail that differs from the lead-in moves nothing', () {
    const s = [
      Section(label: 'A', startMeasure: 1),
      Section(label: 'B', startMeasure: 9, startNote: 4), // A2 e2, not e2
    ];
    expect(movedRepeats(s, measures), isEmpty);
  });

  test('the engraved xml reads |: e2 | … A2 :| e2 |: …', () {
    final out = moveRepeatsOntoLeadIns(
        splitBarsAtSections(xml, sectionBarSplits(sections, measures)),
        movedRepeats(sections, measures));
    final doc = XmlDocument.parse(out);
    String bars(String n) {
      final m = doc
          .findAllElements('measure')
          .firstWhere((m) => m.getAttribute('number') == n);
      return [
        for (final b in m.findElements('barline'))
          '${b.getAttribute('location')}:'
              '${b.findElements('repeat').firstOrNull?.getAttribute('direction') ?? b.findElements('bar-style').first.innerText}',
      ].join(' ');
    }

    expect(bars('1'), 'left:forward');
    expect(bars('2'), '');
    expect(bars('9'), 'right:backward');
    expect(bars('9b'), '');
    expect(bars('10'), 'left:forward');
  });

  group('playedAt', () {
    final map = EngravedMeasureMap.withSplits(
        measures, sectionBarSplits(sections, measures),
        moved: movedRepeats(sections, measures),
        order: ParsedPiece.performanceOrder(measures));

    test('the tail on the pass that jumps back is drawn on the pickup', () {
      expect(map.playedAt(9, 5, 8), (number: 1, note: 0)); // 1st pass of 9
      expect(map.locatePlayed(9, 5, 8), map.locate(1, 0));
    });

    test('on the pass into B, and before the tail, as written', () {
      expect(map.playedAt(9, 5, 16), (number: 9, note: 5)); // 2nd pass
      expect(map.playedAt(9, 4, 8), (number: 9, note: 4));
      expect(map.playedAt(9, 5, -1), (number: 9, note: 5));
    });

    test('a run starting on that tail draws from the pickup', () {
      final r = map.range(9, 5, 9, 5, startPerf: 8)!;
      expect(r.startMeasureIndex, map.firstIndexOf(1));
      expect(r.startNote, 0);
      expect(r.endMeasureIndex, map.firstIndexOf(9)); // 9's head, not 9b
    });
  });
}

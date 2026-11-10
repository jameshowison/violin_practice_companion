import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/section_run.dart';
import 'package:violin_practice_companion/models/section_run_groups.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/widgets/section_loop.dart';
import 'package:violin_practice_companion/widgets/section_minimap.dart';

/// Unfolded runs for a label sequence, one bar each, performance-indexed in
/// order (so every run has a distinct selection).
List<SectionRun> runsOf(String labels) {
  final ls = labels.split(' ');
  return [
    for (var i = 0; i < ls.length; i++)
      SectionRun(
        label: ls[i],
        passIndex: 0,
        passCount: 1,
        firstMeasure: i + 1,
        lastMeasure: i + 1,
        perfStart: i,
        perfEnd: i + 1,
      ),
  ];
}

/// The folded display as text: a loop as `[B C]×2`, a D.C. return as
/// `{D.C.: A B}`.
String shape(List<RunGroup> groups) => groups
    .map((g) {
      final inner = g.slots.map((s) => s.label).join(' ');
      if (g.isJump) return '{${g.jumpLabel}: $inner}';
      return g.isLoop ? '[$inner]×${g.passes}' : inner;
    })
    .join(' ');

void main() {
  group('foldRunGroups', () {
    test('folds every back-to-back repeat, a single section included', () {
      expect(shape(foldRunGroups(runsOf('A A B C B C'))), '[A]×2 [B C]×2');
    });

    test('each folded slot holds every pass, in order', () {
      final g = foldRunGroups(runsOf('A A B C B C'))[1];
      expect(g.slots.map((s) => s.runs).toList(), [
        [2, 4],
        [3, 5],
      ]);
      expect(g.firstRun, 2);
      expect(g.lastRun, 5);
      expect(g.passOf(4), 1);
      expect(g.passOf(0), isNull);
    });

    test('three passes, and a longer block', () {
      expect(shape(foldRunGroups(runsOf('A B A B A B'))), '[A B]×3');
      expect(shape(foldRunGroups(runsOf('A B C A B C D'))), '[A B C]×2 D');
    });

    test('nothing to fold', () {
      expect(shape(foldRunGroups(runsOf('A B C'))), 'A B C');
      expect(foldRunGroups(const []), isEmpty);
    });

    test('a written-out return stays as plain sections', () {
      expect(shape(foldRunGroups(runsOf('A A B C A'))), '[A]×2 B C A');
    });

    test("Gossec: the score's D.C. al Fine becomes one labelled stretch", () {
      // A A B C C D D | D.C. → A B (repeats not taken on the return).
      final groups = foldRunGroups(runsOf('A A B C C D D A B'),
          jump: (perfIndex: 7, label: 'D.C. al Fine'));
      expect(shape(groups), '[A]×2 B [C]×2 [D]×2 {D.C. al Fine: A B}');
      expect(groups.last.firstRun, 7);
      expect(groups.last.lastRun, 8);
    });
  });

  group('RunGroupState', () {
    final runs = runsOf('A A B C B C');
    final groups = foldRunGroups(runs);
    final bc = groups[1];
    const playing = HighlightEvent(
        measureNumber: 1,
        noteIndex: 0,
        isLong: false,
        onsetSeconds: 0,
        offsetSeconds: 1,
        beatPosition: 0,
        performanceIndex: 0);

    test('stopped: nothing lit, no dots', () {
      final st = RunGroupState.of(bc, runs, null, null, null);
      expect((st.lit, st.filled, st.wholeSelected), (false, 0, false));
    });

    test('playing the 2nd pass: lit, both dots filled', () {
      final st = RunGroupState.of(bc, runs, 4, playing, null);
      expect((st.lit, st.filled), (true, 2));
    });

    test('played through: dots stay filled, line goes grey', () {
      final st = RunGroupState.of(groups[0], runs, 4, playing, null);
      expect((st.lit, st.filled), (false, 2));
    });

    test('whole repeat selected: every chip lit', () {
      final sel = MeasureSelection.ofRuns(runs[2], runs[5]);
      final st = RunGroupState.of(bc, runs, 2, null, sel);
      expect((st.wholeSelected, st.lit, st.filled), (true, true, 0));
    });
  });

  test('a selected D.C. return is current at its own A, not the first A', () {
    // Gossec: the return's A shares bar 1 with the first A.
    final runs = [
      for (final (i, l) in [('A'), ('A'), ('B'), ('A'), ('B')].indexed)
        SectionRun(
          label: l,
          passIndex: 0,
          passCount: 1,
          firstMeasure: l == 'A' ? 1 : 2,
          lastMeasure: l == 'A' ? 1 : 2,
          perfStart: i,
          perfEnd: i + 1,
        ),
    ];
    final sel = MeasureSelection.ofRuns(runs[3], runs[4]);
    expect(resolveCurrentRun(runs, false, null, null, sel), 3);
  });

  group('runForSlotTap', () {
    final runs = runsOf('A A B C B C');
    final b = foldRunGroups(runs)[1].slots.first; // B pass 1 = 2, pass 2 = 4

    test('first pass, then the next, then the last again (which clears)', () {
      expect(runForSlotTap(runs, b, null), 2);
      expect(runForSlotTap(runs, b, MeasureSelection.ofRun(runs[2])), 4);
      expect(runForSlotTap(runs, b, MeasureSelection.ofRun(runs[4])), 4);
    });

    test('another selection starts at the first pass', () {
      expect(runForSlotTap(runs, b, MeasureSelection.ofRun(runs[0])), 2);
    });
  });

  test('MeasureSelection.ofRuns spans both passes', () {
    final runs = runsOf('A A B C B C');
    final sel = MeasureSelection.ofRuns(runs[2], runs[5]);
    expect(sel.startMeasure, 3);
    expect(sel.endMeasure, 6);
    expect(sel.startPerf, 2);
    expect(sel.endPerf, 5);
    expect(MeasureSelection.ofRuns(runs[2], runs[2]),
        MeasureSelection.ofRun(runs[2]));
  });
}

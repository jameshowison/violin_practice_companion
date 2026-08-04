import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/fingering_density.dart';
import 'package:violin_practice_companion/models/note_event.dart';

NoteEvent _n(String string, String finger) => NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: false,
      fingerString: string,
      fingerNumber: finger,
    );

/// A note in the middle of a phrase — every landmark flag off, so a predicate can
/// be tested on its own.
FingeringNoteContext _mid(NoteEvent note, NoteEvent? prev) => (
      note: note,
      prev: prev,
      isFirstNote: false,
      isMeasureStart: false,
      afterRest: false,
    );

void main() {
  group('predicates', () {
    test('a string change needs a previous note to change from', () {
      expect(fingeringStringChanged(_mid(_n('E', '1'), _n('A', '1'))), isTrue);
      expect(fingeringStringChanged(_mid(_n('A', '3'), _n('A', '1'))), isFalse);
      // No previous note isn't a "change" — isFirstNote carries that case, and
      // double-counting it would score the opening note 7 instead of 4.
      expect(fingeringStringChanged(_mid(_n('A', '1'), null)), isFalse);
    });

    test('a jump is MORE than two positions, on the numeric part only', () {
      expect(fingeringJumped(_mid(_n('A', '4'), _n('A', '1'))), isTrue);
      expect(fingeringJumped(_mid(_n('A', '0'), _n('A', '3'))), isTrue);
      expect(fingeringJumped(_mid(_n('A', '3'), _n('A', '1'))), isFalse);
      // '2L' → '4' is a jump of 2, so not a jump. A string compare couldn't
      // subtract these at all.
      expect(fingeringJumped(_mid(_n('A', '4'), _n('A', '2L'))), isFalse);
      expect(fingeringJumped(_mid(_n('A', '4'), _n('A', '1H'))), isTrue);
    });

    test('fingerPosition reads the leading digits', () {
      expect(fingerPosition('0'), 0);
      expect(fingerPosition('2L'), 2);
      expect(fingerPosition('3H'), 3);
      expect(fingerPosition(null), isNull);
      expect(fingerPosition('L'), isNull);
    });

    test('L/H is detected on either suffix', () {
      expect(fingeringIsLowHigh(_n('D', '2L')), isTrue);
      expect(fingeringIsLowHigh(_n('E', '3H')), isTrue);
      expect(fingeringIsLowHigh(_n('E', '3')), isFalse);
    });

    test('the label changes when either half does', () {
      expect(fingeringLabelChanged(_mid(_n('A', '1'), _n('A', '1'))), isFalse);
      expect(fingeringLabelChanged(_mid(_n('A', '2'), _n('A', '1'))), isTrue);
      expect(fingeringLabelChanged(_mid(_n('E', '1'), _n('A', '1'))), isTrue);
      expect(fingeringLabelChanged(_mid(_n('A', '1'), null)), isTrue);
    });
  });

  group('fingeringDifficulty', () {
    test('a plain repeat mid-phrase scores zero', () {
      expect(fingeringDifficulty(_mid(_n('A', '1'), _n('A', '1'))), 0);
    });

    test('the first note of the piece scores on its own', () {
      final c = (
        note: _n('A', '1'),
        prev: null,
        isFirstNote: true,
        isMeasureStart: true,
        afterRest: false,
      );
      // first note 4 + measure start 1 + label changed 1 (no previous label).
      expect(fingeringDifficulty(c), 6);
    });

    test('a string change alone clears the "least" threshold', () {
      final c = _mid(_n('E', '1'), _n('A', '1'));
      // string change 3 + label changed 1.
      expect(fingeringDifficulty(c), 4);
      expect(fingeringDifficulty(c),
          greaterThanOrEqualTo(fingeringScoreThreshold(FingeringDensity.least)));
    });

    test('a plain neighbouring step does NOT clear "least"', () {
      // A1 → A2: label changed 1 only.
      final c = _mid(_n('A', '2'), _n('A', '1'));
      expect(fingeringDifficulty(c), 1);
      expect(fingeringDifficulty(c),
          lessThan(fingeringScoreThreshold(FingeringDensity.least)));
    });

    test('landmarks add up to reach "least" without a string change', () {
      // An L finger at a measure start after a rest: 2 + 1 + 1 + 1 = 5.
      final c = (
        note: _n('D', '2L'),
        prev: _n('D', '1'),
        isFirstNote: false,
        isMeasureStart: true,
        afterRest: true,
      );
      expect(fingeringDifficulty(c), 5);
    });
  });

  group('showFingering', () {
    /// Every combination of the five context flags against a fixed previous
    /// note — the whole input space of the rules, so nesting is proved rather
    /// than sampled.
    List<FingeringNoteContext> everyContext() {
      final notes = [
        _n('A', '1'), // repeat of prev
        _n('A', '2'), // step
        _n('A', '4'), // jump
        _n('E', '1'), // string change
        _n('D', '2L'), // L finger + string change
      ];
      final out = <FingeringNoteContext>[];
      for (final note in notes) {
        for (final first in [true, false]) {
          for (final measureStart in [true, false]) {
            for (final rest in [true, false]) {
              out.add((
                note: note,
                prev: _n('A', '1'),
                isFirstNote: first,
                isMeasureStart: measureStart,
                afterRest: rest,
              ));
            }
          }
        }
      }
      return out;
    }

    for (final policy in FingeringDensityPolicy.values) {
      test('$policy: least ⊆ fewer ⊆ all', () {
        for (final c in everyContext()) {
          final all =
              showFingering(c, density: FingeringDensity.all, policy: policy);
          final fewer =
              showFingering(c, density: FingeringDensity.fewer, policy: policy);
          final least =
              showFingering(c, density: FingeringDensity.least, policy: policy);
          expect(all, isTrue, reason: '"all" must show everything');
          if (least) {
            expect(fewer, isTrue,
                reason: 'shown at least but hidden at fewer — the slider would '
                    'ADD a label as it moves towards less detail');
          }
        }
      });
    }

    test('"all" shows a note no rule would ever pick', () {
      final repeat = _mid(_n('A', '1'), _n('A', '1'));
      expect(
          showFingering(repeat,
              density: FingeringDensity.all,
              policy: FingeringDensityPolicy.difficulty),
          isTrue);
      expect(
          showFingering(repeat,
              density: FingeringDensity.fewer,
              policy: FingeringDensityPolicy.difficulty),
          isFalse);
    });

    test('both policies keep every string change at "least"', () {
      final c = _mid(_n('E', '1'), _n('A', '1'));
      for (final policy in FingeringDensityPolicy.values) {
        expect(
            showFingering(c,
                density: FingeringDensity.least, policy: policy),
            isTrue,
            reason: '$policy dropped a string change');
      }
    });

    test('both policies keep every L/H finger at "least"', () {
      // Same string, one step away — only the L suffix makes it worth showing.
      final c = _mid(_n('A', '2L'), _n('A', '1'));
      for (final policy in FingeringDensityPolicy.values) {
        expect(
            showFingering(c,
                density: FingeringDensity.least, policy: policy),
            isTrue,
            reason: '$policy dropped an L finger');
      }
    });

    test('the two policies differ where they are meant to: measure starts', () {
      // A plain repeat at a measure start. "Changes" treats a landmark as worth
      // a label at `fewer`; "difficulty" scores it 1, which also clears `fewer`
      // — the divergence is at `least`, where only a real signal survives.
      final c = (
        note: _n('A', '1'),
        prev: _n('A', '1'),
        isFirstNote: false,
        isMeasureStart: true,
        afterRest: false,
      );
      for (final policy in FingeringDensityPolicy.values) {
        expect(showFingering(c, density: FingeringDensity.fewer, policy: policy),
            isTrue);
        expect(showFingering(c, density: FingeringDensity.least, policy: policy),
            isFalse);
      }
    });
  });
}

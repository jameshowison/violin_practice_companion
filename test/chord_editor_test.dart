import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/duration_step.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/services/chord_editor.dart';

// NoteEvent has no operator==, so assertions compare projections
// (.map((n) => n.isChord) etc.) rather than whole objects.
NoteEvent _n(
  String pitch, {
  NoteValue value = NoteValue.quarter,
  bool dotted = false,
  bool isChord = false,
  bool isRest = false,
}) =>
    NoteEvent(
      pitch: pitch,
      midiNumber: 60,
      octave: 4,
      noteValue: value,
      dotted: dotted,
      isRest: isRest,
      isChord: isChord,
    );

NoteEvent _rest({NoteValue value = NoteValue.quarter}) =>
    _n('R', value: value, isRest: true);

List<bool> _flags(List<NoteEvent> n) => n.map((e) => e.isChord).toList();
List<NoteValue> _values(List<NoteEvent> n) =>
    n.map((e) => e.noteValue).toList();

/// The beat total the editor and Measure.actualUnits compute: chord members
/// add no time.
int _units(List<NoteEvent> notes) => notes.fold<int>(
    0, (s, n) => n.isChord ? s : s + thirtySecondUnits(n.noteValue, n.dotted));

void main() {
  group('group queries', () {
    test('a list of plain notes is all singleton groups', () {
      final notes = [_n('A4'), _n('B4'), _n('C5')];
      expect(ChordEditor.groups(notes), [
        (start: 0, end: 1),
        (start: 1, end: 2),
        (start: 2, end: 3),
      ]);
      for (var i = 0; i < notes.length; i++) {
        expect(ChordEditor.primaryIndexOf(notes, i), i);
        expect(ChordEditor.groupSize(notes, i), 1);
      }
    });

    test('a three-note stack resolves to one group from any member', () {
      final notes = [
        _n('C4'),
        _n('E4', isChord: true),
        _n('G4', isChord: true),
        _n('C5'),
      ];
      for (final i in [0, 1, 2]) {
        expect(ChordEditor.primaryIndexOf(notes, i), 0);
        expect(ChordEditor.groupRange(notes, i), (start: 0, end: 3));
        expect(ChordEditor.groupSize(notes, i), 3);
      }
      expect(ChordEditor.groupRange(notes, 3), (start: 3, end: 4));
      expect(ChordEditor.groups(notes), [(start: 0, end: 3), (start: 3, end: 4)]);
    });

    test('a stray member at index 0 counts as its own primary', () {
      final notes = [_n('C4', isChord: true), _n('D4')];
      expect(ChordEditor.primaryIndexOf(notes, 0), 0);
      expect(ChordEditor.groupRange(notes, 0), (start: 0, end: 1));
    });
  });

  group('normalize repairs the invariant', () {
    test('a leading member loses isChord (nothing to attach to)', () {
      final out = ChordEditor.normalize([_n('C4', isChord: true), _n('D4')]);
      expect(_flags(out), [false, false]);
    });

    test('a rest is never a chord member', () {
      final out = ChordEditor.normalize(
          [_n('C4'), _n('R', isRest: true, isChord: true)]);
      expect(_flags(out), [false, false]);
    });

    test('a rest never owns members', () {
      final out = ChordEditor.normalize([_rest(), _n('C4', isChord: true)]);
      expect(_flags(out), [false, false]);
    });

    test('members are snapped to the primary duration, dot included', () {
      final out = ChordEditor.normalize([
        _n('C4', value: NoteValue.half, dotted: true),
        _n('E4', value: NoteValue.sixteenth, isChord: true),
      ]);
      expect(_values(out), [NoteValue.half, NoteValue.half]);
      expect(out[1].dotted, isTrue);
    });

    test('is idempotent and leaves well-formed input alone', () {
      final good = [_n('C4'), _n('E4', isChord: true), _n('D5')];
      final once = ChordEditor.normalize(good);
      final twice = ChordEditor.normalize(once);
      expect(_flags(once), [false, true, false]);
      expect(_flags(twice), [false, true, false]);
      expect(_values(twice), _values(good));
    });
  });

  group('stackBlockedReason / canStack / canUnstack', () {
    test('a plain note after another note can stack', () {
      final notes = [_n('C4'), _n('E4')];
      expect(ChordEditor.stackBlockedReason(notes, 1), isNull);
      expect(ChordEditor.canStack(notes, 1), isTrue);
    });

    test('index 0 has nothing to stack onto', () {
      expect(ChordEditor.canStack([_n('C4'), _n('E4')], 0), isFalse);
    });

    test('a rest can neither be stacked nor be stacked onto', () {
      expect(ChordEditor.canStack([_n('C4'), _rest()], 1), isFalse);
      expect(ChordEditor.canStack([_rest(), _n('E4')], 1), isFalse);
    });

    test('stacking onto a member targets that member group\'s primary', () {
      // A rest holding a (malformed) member must still be rejected.
      final notes = [_rest(), _n('E4', isChord: true), _n('G4')];
      expect(ChordEditor.canStack(notes, 2), isFalse);
    });

    test('an existing member is unstackable, not stackable', () {
      final notes = [_n('C4'), _n('E4', isChord: true)];
      expect(ChordEditor.canStack(notes, 1), isFalse);
      expect(ChordEditor.canUnstack(notes, 1), isTrue);
      expect(ChordEditor.canUnstack(notes, 0), isFalse);
    });

    test('no selection is blocked for both', () {
      expect(ChordEditor.canStack([_n('C4')], null), isFalse);
      expect(ChordEditor.canUnstack([_n('C4')], null), isFalse);
    });
  });

  group('stack', () {
    test('joins the previous stem and adopts its duration', () {
      final out = ChordEditor.stack(
          [_n('C4', value: NoteValue.half), _n('E4', value: NoteValue.eighth)],
          1);
      expect(_flags(out), [false, true]);
      expect(_values(out), [NoteValue.half, NoteValue.half]);
    });

    test('adopts the dot too', () {
      final out = ChordEditor.stack(
          [_n('C4', value: NoteValue.quarter, dotted: true), _n('E4')], 1);
      expect(out[1].dotted, isTrue);
    });

    test('repeating extends the same group to three notes', () {
      var notes = [_n('C4'), _n('E4'), _n('G4')];
      notes = ChordEditor.stack(notes, 1);
      notes = ChordEditor.stack(notes, 2);
      expect(_flags(notes), [false, true, true]);
      expect(ChordEditor.groupRange(notes, 0), (start: 0, end: 3));
    });

    test('a stacked note carries its own members with it', () {
      // [A, B, C(member of B)] — stacking B must bring C, not orphan it.
      final notes = [
        _n('A4', value: NoteValue.half),
        _n('B4'),
        _n('C5', isChord: true),
      ];
      final out = ChordEditor.stack(notes, 1);
      expect(_flags(out), [false, true, true]);
      expect(ChordEditor.groupRange(out, 0), (start: 0, end: 3));
      expect(_values(out), List.filled(3, NoteValue.half));
    });

    test('never changes the list length and preserves per-note pitch', () {
      final notes = [_n('C4'), _n('E4'), _n('G4')];
      final out = ChordEditor.stack(notes, 1);
      expect(out.length, 3);
      expect(out.map((n) => n.pitch).toList(), ['C4', 'E4', 'G4']);
    });

    test('is a no-op when blocked', () {
      final notes = [_rest(), _n('E4')];
      expect(_flags(ChordEditor.stack(notes, 1)), [false, false]);
    });

    test('the bar total drops by exactly the stacked note\'s value', () {
      final notes = [_n('C4'), _n('E4'), _n('G4'), _n('B4')];
      expect(_units(notes), 32); // four quarters
      expect(_units(ChordEditor.stack(notes, 1)), 24);
    });
  });

  group('unstack', () {
    test('is the exact inverse of stack for the last member', () {
      final before = [_n('C4'), _n('E4'), _n('G4')];
      final after = ChordEditor.unstack(ChordEditor.stack(before, 1), 1);
      expect(_flags(after), _flags(before));
      expect(_values(after), _values(before));
      expect(after.map((n) => n.pitch).toList(),
          before.map((n) => n.pitch).toList());
    });

    test('unstacking a middle member splits one chord into two', () {
      final notes = [
        _n('C4'),
        _n('E4', isChord: true),
        _n('G4', isChord: true),
      ];
      final out = ChordEditor.unstack(notes, 1);
      expect(ChordEditor.groups(out), [(start: 0, end: 1), (start: 1, end: 3)]);
    });

    test('is a no-op on a note that is not a member', () {
      final notes = [_n('C4'), _n('E4')];
      expect(_flags(ChordEditor.unstack(notes, 1)), [false, false]);
    });
  });

  group('setDuration applies to the whole stack', () {
    test('from the primary', () {
      final notes = [_n('C4'), _n('E4', isChord: true), _n('G5')];
      final out = ChordEditor.setDuration(
          notes, 0, const DurationStep(NoteValue.eighth, true));
      expect(_values(out),
          [NoteValue.eighth, NoteValue.eighth, NoteValue.quarter]);
      expect(out.map((n) => n.dotted).toList(), [true, true, false]);
    });

    test('from a member — the primary and its siblings follow', () {
      final notes = [
        _n('C4'),
        _n('E4', isChord: true),
        _n('G4', isChord: true),
      ];
      final out = ChordEditor.setDuration(
          notes, 2, const DurationStep(NoteValue.whole, false));
      expect(_values(out), List.filled(3, NoteValue.whole));
    });
  });

  group('insertAfter never lands inside a stack', () {
    test('after a plain note it lands at i + 1', () {
      final r = ChordEditor.insertAfter([_n('C4'), _n('D4')], 0, _n('X4'));
      expect(r.selectedIndex, 1);
      expect(r.notes.map((n) => n.pitch).toList(), ['C4', 'X4', 'D4']);
    });

    test('after a primary it lands past the whole group', () {
      final notes = [
        _n('C4'),
        _n('E4', isChord: true),
        _n('G4', isChord: true),
        _n('D5'),
      ];
      final r = ChordEditor.insertAfter(notes, 0, _n('X4'));
      expect(r.selectedIndex, 3);
      expect(_flags(r.notes), [false, true, true, false, false]);
      expect(ChordEditor.groupRange(r.notes, 0), (start: 0, end: 3));
    });

    test('from a member it also lands past the whole group', () {
      final notes = [_n('C4'), _n('E4', isChord: true), _n('D5')];
      final r = ChordEditor.insertAfter(notes, 1, _n('X4'));
      expect(r.selectedIndex, 2);
      expect(r.notes[2].isChord, isFalse);
    });
  });

  group('deleteAt', () {
    test('removing a member leaves the rest of the stack intact', () {
      final notes = [
        _n('C4'),
        _n('E4', isChord: true),
        _n('G4', isChord: true),
      ];
      final r = ChordEditor.deleteAt(notes, 1);
      expect(_flags(r.notes), [false, true]);
      expect(r.notes.map((n) => n.pitch).toList(), ['C4', 'G4']);
    });

    test('removing the only member leaves a plain note', () {
      final r = ChordEditor.deleteAt([_n('C4'), _n('E4', isChord: true)], 1);
      expect(_flags(r.notes), [false]);
    });

    test('removing a primary promotes its first member', () {
      final notes = [
        _n('C4', value: NoteValue.half),
        _n('E4', value: NoteValue.half, isChord: true),
        _n('G4', value: NoteValue.half, isChord: true),
        _n('D5'),
      ];
      final r = ChordEditor.deleteAt(notes, 0);
      expect(r.notes.map((n) => n.pitch).toList(), ['E4', 'G4', 'D5']);
      expect(_flags(r.notes), [false, true, false]);
      // The promoted note keeps the group's duration, so the bar is unchanged.
      expect(_units(r.notes), _units(notes));
    });

    test('deleting the last remaining note clears the selection', () {
      final r = ChordEditor.deleteAt([_n('C4')], 0);
      expect(r.notes, isEmpty);
      expect(r.selectedIndex, isNull);
    });
  });

  group('toggleRest', () {
    test('is blocked anywhere inside a stack', () {
      final notes = [_n('C4'), _n('E4', isChord: true)];
      expect(ChordEditor.restBlockedReason(notes, 0), isNotNull);
      expect(ChordEditor.restBlockedReason(notes, 1), isNotNull);
      expect(ChordEditor.toggleRest(notes, 1)[1].isRest, isFalse);
      expect(ChordEditor.toggleRest(notes, 0)[0].isRest, isFalse);
    });

    test('works on a plain note and back again', () {
      var notes = [_n('C4'), _n('D4')];
      expect(ChordEditor.restBlockedReason(notes, 0), isNull);
      notes = ChordEditor.toggleRest(notes, 0);
      expect(notes[0].isRest, isTrue);
      notes = ChordEditor.toggleRest(notes, 0);
      expect(notes[0].isRest, isFalse);
      expect(notes[0].pitch, 'C4');
    });

    test('a rest with no usable pitch becomes B4', () {
      final out = ChordEditor.toggleRest([_rest()], 0);
      expect(out[0].pitch, 'B4');
      expect(out[0].isRest, isFalse);
    });
  });

  group('repitch', () {
    const source = NoteEvent(
      pitch: 'E5',
      midiNumber: 76,
      octave: 5,
      noteValue: NoteValue.half,
      dotted: true,
      isRest: false,
      isChord: true,
      chordSymbol: 'Am7',
      displayAccidental: 'natural',
      scoreFinger: 2,
      fingerNumber: 'A2L',
      fingerString: 'A',
    );

    test('carries the structural fields through — the regression lock', () {
      final out = ChordEditor.repitch(source,
          pitch: 'F5', midiNumber: 77, octave: 5);
      expect(out.isChord, isTrue, reason: 'a pitch nudge must not un-chord');
      expect(out.chordSymbol, 'Am7');
      expect(out.noteValue, NoteValue.half);
      expect(out.dotted, isTrue);
      expect(out.pitch, 'F5');
      expect(out.midiNumber, 77);
    });

    test('drops the now-stale fingering by default', () {
      final out = ChordEditor.repitch(source,
          pitch: 'F5', midiNumber: 77, octave: 5);
      expect(out.scoreFinger, isNull);
      expect(out.fingerNumber, isNull);
      expect(out.fingerString, isNull);
    });

    test('keeps the fingering when the sounding pitch is unchanged', () {
      final out = ChordEditor.repitch(source,
          pitch: 'E5', midiNumber: 76, octave: 5, keepFingering: true);
      expect(out.fingerNumber, 'A2L'); // verbatim — see CLAUDE.md
      expect(out.scoreFinger, 2);
    });

    test('clears displayAccidental when omitted (copyWith cannot)', () {
      final out = ChordEditor.repitch(source,
          pitch: 'E5', midiNumber: 76, octave: 5);
      expect(out.displayAccidental, isNull);
      expect(source.copyWith().displayAccidental, 'natural');
    });
  });

  group('normalizeMarkers pin section starts to a primary', () {
    test('a marker on a member moves to its primary', () {
      final notes = [
        _n('C4'),
        _n('E4', isChord: true),
        _n('G4', isChord: true),
      ];
      final out = ChordEditor.normalizeMarkers(
          notes, [const Section(label: 'B', startMeasure: 6, startNote: 2)], 6);
      expect(out.single.startNote, 0);
      expect(out.single.label, 'B');
    });

    test('markers already on a primary and in other measures are untouched', () {
      final notes = [_n('C4'), _n('E4', isChord: true), _n('G5')];
      final out = ChordEditor.normalizeMarkers(notes, const [
        Section(label: 'A', startMeasure: 6, startNote: 2),
        Section(label: 'C', startMeasure: 9, startNote: 1),
      ], 6);
      expect(out.map((s) => (s.label, s.startMeasure, s.startNote)).toList(),
          [('A', 6, 2), ('C', 9, 1)]);
    });

    test('two markers collapsing onto one primary dedupe last-wins', () {
      final notes = [_n('C4'), _n('E4', isChord: true)];
      final out = ChordEditor.normalizeMarkers(notes, const [
        Section(label: 'A', startMeasure: 6, startNote: 0),
        Section(label: 'B', startMeasure: 6, startNote: 1),
      ], 6);
      expect(out.length, 1);
      expect(out.single.label, 'B');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:violin_practice_companion/models/support_level.dart';

void main() {
  const all = SupportLevel.values;

  group('supportLadder', () {
    test('a fully annotated view with bowings has every step', () {
      expect(
          supportLadder(fullHasMore: true, fullHasNames: false, hasCues: true),
          all);
    });

    test('no bowings: no bowings step', () {
      expect(
          supportLadder(fullHasMore: true, fullHasNames: true, hasCues: false),
          isNot(contains(SupportLevel.bowings)));
    });

    test('a view of names alone starts at Letters', () {
      expect(
          supportLadder(fullHasMore: false, fullHasNames: true, hasCues: false)
              .first,
          SupportLevel.letters);
    });

    test('no row for names in the layout: no letters step', () {
      expect(
          supportLadder(
              fullHasMore: true,
              fullHasNames: false,
              hasCues: false,
              namesHaveRoom: false),
          isNot(contains(SupportLevel.letters)));
    });

    test('a bare staff never adds names', () {
      expect(
          supportLadder(fullHasMore: false, fullHasNames: false, hasCues: false),
          [SupportLevel.staff, SupportLevel.dimmed, SupportLevel.black]);
    });
  });

  group('stepping', () {
    final ladder =
        supportLadder(fullHasMore: false, fullHasNames: true, hasCues: false);

    test('fewer and more stop at the ends', () {
      expect(fewerSupports(SupportLevel.black, ladder), SupportLevel.black);
      expect(moreSupports(SupportLevel.letters, ladder), SupportLevel.letters);
    });

    test('skips steps the ladder lacks', () {
      expect(fewerSupports(SupportLevel.staff, ladder), SupportLevel.dimmed);
      expect(moreSupports(SupportLevel.dimmed, ladder), SupportLevel.staff);
    });

    test('a level the ladder lost snaps to the next with less help', () {
      expect(snapToLadder(SupportLevel.full, ladder), SupportLevel.letters);
      expect(snapToLadder(SupportLevel.bowings, ladder), SupportLevel.dimmed);
    });
  });

  group('PracticeState', () {
    const start = PracticeState(active: true, level: SupportLevel.full);

    test('Fade steps down; a peek steps back up', () {
      final faded = start.fade(all);
      expect(faded.level, SupportLevel.letters);
      expect(
          faded.peek(all, autoFade: false, refadeAfterPeek: true).level,
          SupportLevel.full);
    });

    test('a peek at the top changes nothing', () {
      expect(
          identical(start.peek(all, autoFade: true, refadeAfterPeek: false),
              start),
          isTrue);
    });

    test('a loop pass fades only with auto-fade on', () {
      expect(start.loopPassed(all, autoFade: false).level, SupportLevel.full);
      expect(start.loopPassed(all, autoFade: true).level, SupportLevel.letters);
    });

    test('with refade on, fading carries on after a peek', () {
      final s = start
          .fade(all)
          .peek(all, autoFade: true, refadeAfterPeek: true)
          .loopPassed(all, autoFade: true);
      expect(s.level, SupportLevel.letters);
    });

    test('with refade off, a peek pauses fading until Fade', () {
      var s = start
          .fade(all)
          .peek(all, autoFade: true, refadeAfterPeek: false);
      expect(s.autoFadePaused, isTrue);
      s = s.loopPassed(all, autoFade: true);
      expect(s.level, SupportLevel.full);
      s = s.fade(all);
      expect(s.autoFadePaused, isFalse);
      expect(s.loopPassed(all, autoFade: true).level, SupportLevel.staff);
    });
  });

  test('cueBarsOf: the bars with a bow mark on any note', () {
    NoteEvent note(Bowing? b) => NoteEvent(
          pitch: 'A',
          midiNumber: 69,
          octave: 4,
          noteValue: NoteValue.quarter,
          dotted: false,
          isRest: false,
          bowing: b,
        );
    final piece = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      measures: [
        Measure(number: 1, notes: [note(Bowing.down), note(null)]),
        Measure(number: 2, notes: [note(null)]),
        Measure(number: 3, notes: [note(null), note(Bowing.up)]),
      ],
    );
    expect(cueBarsOf(piece), {1, 3});
  });
}

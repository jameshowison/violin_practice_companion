import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/gdae_tuning.dart';
import 'package:violin_practice_companion/services/fingering_annotation_builder.dart'
    show maxFirstPositionFret;

void main() {
  group('stringFor', () {
    test('each open string resolves to itself', () {
      for (final e in GdaeTuning.openMidi.entries) {
        expect(GdaeTuning.stringFor(e.value), e.key,
            reason: 'open ${e.key} should be the ${e.key} string');
      }
    });

    test('prefers the highest string that keeps the fret low', () {
      // A4 (69) is the open A, but it is also fret 7 on D. "Highest" picks A.
      expect(GdaeTuning.stringFor(69), 'A');
      // D5 (74) is fret 5 on A, and fret 12 on D — A wins.
      expect(GdaeTuning.stringFor(74), 'A');
      // B3 (59) is fret 4 on G; the D string can't reach down to it.
      expect(GdaeTuning.stringFor(59), 'G');
    });

    test('notes outside the range fall back to the nearest end', () {
      expect(GdaeTuning.stringFor(40), 'G'); // below the G string
      expect(GdaeTuning.stringFor(100), 'E'); // way above the E string
    });
  });

  group('resolve', () {
    test('an open string is fret 0', () {
      final at = GdaeTuning.resolve(69, fingerString: 'A');
      expect(at.string, 'A');
      expect(at.fret, 0);
    });

    test('following the fingering can reach fret 7', () {
      // D4 played as the G string's 4th finger.
      final at = GdaeTuning.resolve(62, fingerString: 'G');
      expect(at.string, 'G');
      expect(at.fret, 7);
    });

    test('preferring open frets moves the same note to the next string', () {
      // The identical note, resolved the beginner way: open D instead of G7.
      final at =
          GdaeTuning.resolve(62, fingerString: 'G', preferOpenFrets: true);
      expect(at.string, 'D');
      expect(at.fret, 0);
    });

    test('preferring open frets keeps frets low, except atop the E string', () {
      // The first-position range the fingering table covers, G3..B5. Everything
      // in it lands at 6 or below by moving to a higher string — everything
      // except the notes above the E string's 6th fret, which have no higher
      // string to move to. B5 (83) is the top of the table and comes out at E7.
      for (var midi = 55; midi <= 83; midi++) {
        final at = GdaeTuning.resolve(midi, preferOpenFrets: true);
        final ceiling = at.string == 'E' ? maxFirstPositionFret : 6;
        expect(at.fret, inInclusiveRange(0, ceiling),
            reason: 'midi $midi came out at fret ${at.fret} on ${at.string}');
      }
      expect(GdaeTuning.resolve(83, preferOpenFrets: true),
          (string: 'E', fret: 7));
    });

    test('first position never needs two digits, either way round', () {
      // What lets the channel's chips stay square-ish — see
      // [maxFirstPositionFret]. First position spans the open string to its 4th
      // finger, which is 7 semitones, so those are the only (string, note)
      // pairings the fingering table can produce.
      for (final s in GdaeTuning.openMidi.keys) {
        for (var fret = 0; fret <= maxFirstPositionFret; fret++) {
          final midi = GdaeTuning.openMidi[s]! + fret;
          for (final open in [true, false]) {
            final at = GdaeTuning.resolve(midi,
                fingerString: s, preferOpenFrets: open);
            expect(at.fret, inInclusiveRange(0, maxFirstPositionFret),
                reason: 'midi $midi (${s}$fret) came out at '
                    '${at.string}${at.fret} with open=$open');
          }
        }
      }
    });

    test('a null fingering string falls back to the derived one', () {
      final at = GdaeTuning.resolve(69);
      expect(at.string, 'A');
      expect(at.fret, 0);
    });

    test('string numbers run 1=E to 4=G, matching the tab lines', () {
      expect(GdaeTuning.stringNumber, {'E': 1, 'A': 2, 'D': 3, 'G': 4});
    });
  });
}

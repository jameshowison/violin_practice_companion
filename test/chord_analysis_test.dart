import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/services/chord_analysis.dart';

String? rn(int fifths, KeyMode mode, String chord) => ChordAnalysis.romanNumeral(
    keyFifths: fifths, keyMode: mode, chordName: chord);

void main() {
  group('major keys', () {
    test('the primary triads of D major', () {
      expect(rn(2, KeyMode.major, 'D'), 'I');
      expect(rn(2, KeyMode.major, 'G'), 'IV');
      expect(rn(2, KeyMode.major, 'A'), 'V');
      expect(rn(2, KeyMode.major, 'A7'), 'V7');
      expect(rn(2, KeyMode.major, 'Bm'), 'vi');
      expect(rn(2, KeyMode.major, 'C#dim'), 'vii°');
    });

    test('a borrowed flat-seven is marked chromatic', () {
      expect(rn(2, KeyMode.major, 'C'), '♭VII');
    });
  });

  group('minor keys', () {
    test('A minor reads against the natural-minor scale', () {
      expect(rn(0, KeyMode.minor, 'Am'), 'i');
      expect(rn(0, KeyMode.minor, 'Dm'), 'iv');
      expect(rn(0, KeyMode.minor, 'G'), 'VII');
      expect(rn(0, KeyMode.minor, 'E'), 'V'); // raised third, harmonic minor
    });
  });

  group('mixolydian — the Old Joe Clark case', () {
    // K: Amix carries D major's two sharps, but the tonic is A. Reading only
    // the signature made the opening A chord come out as V.
    const fifths = 2;
    const mode = KeyMode.mixolydian;

    test('the tonic chord is I, not V', () {
      expect(rn(fifths, mode, 'A'), 'I');
    });

    test('E is V and G is the characteristic flat-seven', () {
      expect(rn(fifths, mode, 'E'), 'V');
      expect(rn(fifths, mode, 'G'), '♭VII');
    });

    test('the same chords in D major still read as V / II / IV', () {
      // Guards the distinction: identical signature, different tonic.
      expect(rn(fifths, KeyMode.major, 'A'), 'V');
      expect(rn(fifths, KeyMode.major, 'G'), 'IV');
    });
  });

  group('the other modes resolve their own tonic', () {
    test('D dorian (no accidentals) — i, VII, and the major IV', () {
      expect(rn(0, KeyMode.dorian, 'Dm'), 'i');
      // Read against natural minor (dorian has a ♭3), where the ♭7 chord is
      // diatonic — so plain VII, matching the A-minor case above. Only the
      // bright modes get a ♭ prefix there (see the mixolydian group).
      expect(rn(0, KeyMode.dorian, 'C'), 'VII');
      expect(rn(0, KeyMode.dorian, 'G'), 'IV'); // the dorian signature chord
    });

    test('E phrygian (no accidentals)', () {
      expect(rn(0, KeyMode.phrygian, 'Em'), 'i');
      expect(rn(0, KeyMode.phrygian, 'F'), '♭II');
    });

    test('F lydian (no accidentals)', () {
      expect(rn(0, KeyMode.lydian, 'F'), 'I');
      expect(rn(0, KeyMode.lydian, 'G'), 'II');
    });

    test('G mixolydian (no accidentals)', () {
      expect(rn(0, KeyMode.mixolydian, 'G'), 'I');
      expect(rn(0, KeyMode.mixolydian, 'F'), '♭VII');
    });

    test('B locrian (no accidentals)', () {
      expect(rn(0, KeyMode.locrian, 'Bdim'), 'i°');
    });
  });

  test('an unparseable chord name returns null', () {
    expect(rn(0, KeyMode.major, ''), isNull);
    expect(rn(0, KeyMode.major, 'H'), isNull);
  });

  group('analyze — the fields the chord palette colors by', () {
    ({String roman, int degreeIndex, bool minorQuality})? an(
            int fifths, KeyMode mode, String chord) =>
        ChordAnalysis.analyze(
            keyFifths: fifths, keyMode: mode, chordName: chord);

    test('degreeIndex ignores the ♭/♯ prefix, so a hue is per scale step', () {
      // Old Joe Clark: the borrowed G reads ♭VII but must color as VII.
      expect(an(2, KeyMode.mixolydian, 'G')?.degreeIndex, 6);
      expect(an(2, KeyMode.mixolydian, 'G')?.roman, '♭VII');
      expect(an(2, KeyMode.mixolydian, 'A')?.degreeIndex, 0);
      expect(an(2, KeyMode.mixolydian, 'E')?.degreeIndex, 4);
    });

    test('quality shades the degree rather than moving it', () {
      // IV and iv are the same scale step, so they share a hue and differ only
      // in shade — that's the whole reason minorQuality is separate.
      final major = an(0, KeyMode.major, 'F')!; // IV of C major
      final minor = an(-3, KeyMode.minor, 'Fm')!; // iv of C minor
      expect(major.degreeIndex, 3);
      expect(major.minorQuality, isFalse);
      expect(minor.degreeIndex, 3);
      expect(minor.minorQuality, isTrue);
    });

    test('diminished counts as the darker quality, augmented does not', () {
      expect(an(2, KeyMode.major, 'C#dim')?.minorQuality, isTrue);
      expect(an(0, KeyMode.major, 'Caug')?.minorQuality, isFalse);
      // A major seventh is still major.
      expect(an(2, KeyMode.major, 'A7')?.minorQuality, isFalse);
      expect(an(2, KeyMode.major, 'Bm7')?.minorQuality, isTrue);
    });

    test('an unparseable name yields null, like romanNumeral', () {
      expect(an(0, KeyMode.major, 'H'), isNull);
      expect(an(0, KeyMode.major, ''), isNull);
    });
  });
}

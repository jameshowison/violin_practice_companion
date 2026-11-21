import 'dart:math' as math;

import 'package:pitch_tuner/pitch_tuner.dart';
import 'package:test/test.dart';

/// Frames every ~10.7 ms (a 512-sample hop at 48 kHz), from [ms] onwards.
TunerFrame frame(int i, double? hz, {double clarity = 0.97, double rms = 0.05}) =>
    TunerFrame(Duration(microseconds: (i * 512 * 1e6 / 48000).round()),
        hz == null ? null : PitchEstimate(hz: hz, clarity: clarity, rms: rms));

double off(double hz, double cents) => hz * math.pow(2, cents / 1200);

void main() {
  group('TunerModel', () {
    final violin = InstrumentTuning.violin();
    final mandolin = InstrumentTuning.mandolin();
    final a = violin.strings[2], d = violin.strings[1];

    /// Drives a model on a running clock, a frame per 512-sample hop.
    late TunerModel m;
    var i = 0;
    void start(InstrumentTuning t, {String? pin}) {
      m = TunerModel(t);
      if (pin != null) m.pinned = pin;
      i = 0;
    }

    /// [n] frames of [hz] (or a function of the frame's age in seconds), at
    /// [rms] (or a function of age, for a fading pluck), starting [after]
    /// frames into the sound.
    void sound(int n, Object hz, {Object rms = 0.05, double clarity = 0.97, int after = 0}) {
      for (var k = 0; k < n; k++) {
        final age = (k + after) * 512 / 48000;
        final h = hz is double ? hz : (hz as double Function(double))(age);
        final r = rms is double ? rms : (rms as double Function(double))(age);
        m.add(frame(i++, h, clarity: clarity, rms: r));
      }
    }

    void silence(int n) {
      for (var k = 0; k < n; k++) {
        m.add(frame(i++, null));
      }
    }

    test('a pluck that drops 10 dB after its attack and rings on quietly still reads', () {
      // An A course, 2026-11-17: 0.09 at the pick, a third of that 150 ms on,
      // then a clean A ringing 15-20 dB down. Read only at full strength it
      // never reached a reading, and the screen said "Play a string".
      start(mandolin, pin: 'A4');
      silence(20);
      sound(80, off(440, -6), rms: (double t) => t < 0.12 ? 0.09 : 0.09 * math.max(0.12, math.exp(-(t - 0.12) * 7)),
          clarity: 0.93);
      expect(m.reading, isNotNull);
      expect(m.reading!.cents, closeTo(-6, 1));
    });

    // A pluck: sharp by [glide] at the start, falling back as it fades.
    double Function(double) pluckHz(double hz, {double glide = 0}) =>
        (t) => off(hz, glide * math.exp(-t / 0.45));
    double fading(double t) => 0.2 * math.exp(-t / 0.9);

    test('listening: a pluck until it settles, a bow until its level has held', () {
      start(violin, pin: 'A4');
      expect(m.listening, isFalse);
      sound(30, pluckHz(off(a.hz, -10), glide: 12), rms: fading); // 0.32 s
      expect(m.listening, isTrue, reason: 'a pluck still gliding down');
      sound(70, pluckHz(off(a.hz, -10), glide: 12), rms: fading, after: 30); // 1.07 s
      expect(m.listening, isFalse);
      silence(60);
      expect(m.listening, isFalse, reason: 'over, not listening');
      sound(15, off(a.hz, -10)); // a bow, 0.16 s
      expect(m.listening, isTrue);
      sound(55, off(a.hz, -10), after: 15); // 0.75 s, its level held
      expect(m.listening, isFalse);
    });

    test('a picked string slipping to its octave stays the string, not very sharp', () {
      // A session: a G 60 cents flat read +1165 (its octave) and said "Very sharp".
      final g = mandolin.strings[0];
      start(mandolin, pin: 'G3');
      sound(100, off(g.hz, -60));
      expect(m.reading!.cents, closeTo(-60, 2));
      sound(60, off(g.hz * 2, -60)); // the detector on the second harmonic, steady
      expect(m.reading!.cents, closeTo(-60, 2));
      silence(50);
      // A fresh pluck heard wholly an octave up (an inside G with a weak
      // fundamental, 2026-11-17): read as the string, not thrown away.
      sound(100, off(g.hz * 2, -40), rms: 0.2);
      expect(m.reading!.cents, closeTo(-40, 2), reason: 'the string, read back down from its octave');
      sound(60, off(g.hz * 3, -40), rms: 0.2); // and from its twelfth
      expect(m.reading!.cents, closeTo(-40, 2));
      sound(100, off(g.hz, -40), rms: 0.3);
      expect(m.reading!.cents, closeTo(-40, 2));
    });

    test("the pair's other string starts afresh: no trend from the last string", () {
      final e = mandolin.strings[3];
      start(mandolin, pin: 'E5');
      sound(120, pluckHz(off(e.hz, 2)), rms: fading);
      silence(60);
      m.newString(); // the other E
      sound(120, pluckHz(off(e.hz, 12)), rms: fading);
      expect(m.reading!.trend, TunerTrend.none);
      expect(m.reading!.cents, greaterThan(8));
    });

    test('steady flat A reads flat on A', () {
      start(violin);
      sound(45, off(a.hz, -12));
      expect(m.reading!.string.name, 'A4');
      expect(m.reading!.cents, closeTo(-12, 0.01));
      expect(m.reading!.live, isTrue);
      expect(m.reading!.inTune, isFalse);
    });

    test('skips the attack, then waits for ~0.2 s of the note', () {
      start(violin);
      sound(10, off(a.hz, 30)); // ~107 ms of a bow's scrape
      expect(m.reading, isNull);
      sound(19, a.hz);
      expect(m.reading, isNull, reason: 'a knock or a brushed string is this long');
      sound(1, a.hz);
      expect(m.reading!.cents, closeTo(0, 0.01));
    });

    test('ignores unclear frames, an octave blip, and a run of subharmonics', () {
      start(violin);
      sound(40, off(a.hz, 4));
      sound(1, a.hz * 2); // an octave blip
      sound(1, 300.0, clarity: 0.4); // noise
      sound(8, a.hz / 2); // a beat's null, locked an octave down
      sound(8, a.hz / 3); // and a twelfth
      sound(1, off(a.hz, 4));
      expect(m.reading!.cents, closeTo(4, 0.01));
    });

    test('ignores a pluck\'s fading tail and a beat\'s null, however clear', () {
      start(mandolin, pin: 'A4');
      sound(40, a.hz, rms: 0.2);
      sound(10, off(a.hz, 45), rms: 0.06); // 10 dB down on the last 300 ms
      expect(m.reading!.cents, closeTo(0, 0.01));
      sound(40, off(a.hz, 20), rms: 0.02); // 20 dB under the peak
      expect(m.reading!.cents, closeTo(0, 0.01));
    });

    test('a hard pluck settles near its rest pitch, not its sharp start', () {
      start(mandolin, pin: 'A4');
      silence(3);
      sound(150, pluckHz(a.hz, glide: 15), rms: fading); // 1.6 s
      // At 1.6 s the string is still 0.5¢ sharp; the median of the last
      // 0.4 s lags it a little.
      expect(m.reading!.cents, inInclusiveRange(0, 1.5));
      expect(m.reading!.inTune, isTrue);
    });

    test('holds the last note\'s pose after it stops, then goes idle', () {
      start(violin);
      sound(30, off(a.hz, -9));
      silence(20); // ~210 ms: a dropout, still live
      expect(m.reading!.live, isTrue);
      silence(30); // ~530 ms: the note has stopped
      expect(m.reading!.live, isFalse);
      expect(m.reading!.cents, closeTo(-9, 0.01), reason: 'the pose of the last bow');
      silence(900); // ~10 s
      expect(m.reading!.cents, closeTo(-9, 0.01));
      silence(1100); // past 20 s
      expect(m.reading, isNull);
    });

    test('in tune with hysteresis: in at 3¢ once the note holds, out only past 5¢', () {
      start(violin);
      sound(30, off(a.hz, 2.5)); // 320 ms, of which 220 after the attack
      expect(m.reading!.inTune, isFalse, reason: 'just shown, not held long enough yet');
      sound(45, off(a.hz, 2.5)); // shown, held 300 ms, then in tune for 150
      expect(m.reading!.inTune, isTrue);
      sound(60, off(a.hz, 4.5)); // drifts to 4.5: still in tune
      expect(m.reading!.cents, closeTo(4.5, 0.01));
      expect(m.reading!.inTune, isTrue);
      sound(60, off(a.hz, 6));
      expect(m.reading!.inTune, isFalse);
      sound(60, off(a.hz, 4.5)); // and back to 4.5 is not in tune again
      expect(m.reading!.inTune, isFalse);
    });

    test('a flat pluck gliding down through in tune is not called in tune', () {
      start(mandolin, pin: 'A4');
      silence(3);
      // 8¢ flat, plucked hard enough to start 10¢ sharp.
      for (var k = 0; k < 150; k++) {
        sound(1, pluckHz(off(a.hz, -8), glide: 10), rms: fading, after: k);
        expect(m.reading?.inTune ?? false, isFalse, reason: 'at ${(k * 10.7).round()} ms');
      }
      expect(m.reading!.cents, closeTo(-8, 1.5));
    });

    test('a pluck that settles in tune is called in tune', () {
      start(mandolin, pin: 'A4');
      silence(3);
      sound(85, pluckHz(off(a.hz, -1), glide: 10), rms: fading); // 0.9 s
      expect(m.reading!.inTune, isFalse, reason: 'not settled yet');
      sound(30, pluckHz(off(a.hz, -1), glide: 10), rms: fading, after: 85);
      expect(m.reading!.inTune, isTrue);
    });

    test('pinned string measures everything against it', () {
      start(violin, pin: 'D4');
      sound(40, a.hz);
      expect(m.reading!.string.name, 'D4');
      expect(m.reading!.cents, closeTo(701.96, 0.01)); // a pure fifth up
    });

    test('follows a move to another string, not a brush of it', () {
      start(violin);
      sound(30, d.hz);
      sound(6, a.hz);
      expect(m.reading!.string.name, 'D4');
      expect(m.reading!.cents, closeTo(0, 0.01), reason: 'the brush is ignored');
      sound(40, a.hz); // a slur: no new onset, but a dozen agree
      expect(m.reading!.string.name, 'A4');
      expect(m.reading!.cents, closeTo(0, 0.01));
    });

    test('a gliding voice does not start a note; a steady retune does', () {
      start(violin, pin: 'G3');
      final g = violin.strings[0];
      sound(60, off(g.hz, -3));
      // Around 174 Hz (-195¢) but wavering by ±18¢, as the session's voice
      // did (175, 172, 176 Hz in 128 ms): near enough to agree, never steady.
      sound(30, (double t) => off(174, 18 * math.sin(2 * math.pi * t / 0.12)));
      expect(m.reading!.cents, closeTo(-3, 0.5));
      // The same distance, held: a peg let down a long way.
      sound(30, 175.0);
      expect(m.reading!.cents, closeTo(centsBetween(175, g.hz), 0.5));
    });

    test('far under the lowest string is not a string', () {
      start(violin, pin: 'G3');
      final g = violin.strings[0];
      sound(60, off(g.hz, -3));
      sound(60, 134.0); // -642¢: the session's last reading
      expect(m.reading!.cents, closeTo(-3, 0.5));
    });

    test('a note that ended in tune goes back to waiting after a few seconds', () {
      start(violin);
      sound(80, a.hz);
      expect(m.reading!.inTune, isTrue);
      silence(200); // ~2 s
      expect(m.reading, isNotNull);
      silence(200); // past 3 s after the note ended
      expect(m.reading, isNull);
    });

    test('A = 442 moves the targets', () {
      start(InstrumentTuning.violin(a4: 442));
      sound(40, 440.0);
      expect(m.reading!.cents, closeTo(-7.85, 0.01));
    });

    group('trend', () {
      // Re-plucked while still ringing, 1.2 s apart, as a player does while
      // turning a tuner.
      void pluck(double cents) =>
          sound(112, pluckHz(off(a.hz, cents), glide: 12), rms: fading);

      test('counts in-tune plucks in a row, and starts again when one is out', () {
        start(mandolin, pin: 'A4');
        silence(3);
        pluck(-20);
        expect(m.reading!.inTuneRun, 0);
        pluck(1);
        expect(m.reading!.inTuneRun, 1);
        pluck(-1);
        expect(m.reading!.inTuneRun, 2);
        pluck(0.5);
        expect(m.reading!.inTuneRun, 3);
        pluck(12);
        expect(m.reading!.inTuneRun, 0, reason: 'out again: the run is over');
        pluck(0);
        expect(m.reading!.inTuneRun, 1);
        m.newString();
        silence(3);
        pluck(0);
        expect(m.reading!.inTuneRun, 1, reason: "the pair's other string counts its own");
      });

      test('between plucks: wrong way, closer, too far', () {
        start(mandolin, pin: 'A4');
        silence(3);
        pluck(-20);
        expect(m.reading!.trend, TunerTrend.none, reason: 'nothing to compare with');
        pluck(-28);
        expect(m.reading!.cents, closeTo(-28, 1.5));
        expect(m.reading!.trend, TunerTrend.wrongWay);
        pluck(-14);
        expect(m.reading!.trend, TunerTrend.closer);
        pluck(12);
        expect(m.reading!.trend, TunerTrend.overshot);
        pluck(1);
        expect(m.reading!.inTune, isTrue);
        expect(m.reading!.trend, TunerTrend.none);
      });

      test('a pluck is not judged during its glide', () {
        start(mandolin, pin: 'A4');
        silence(3);
        pluck(-20);
        // The next one, as flat, plucked harder. Early on its glide makes it
        // read sharper, which would look like "closer".
        sound(30, pluckHz(off(a.hz, -20), glide: 25), rms: fading);
        expect(m.reading!.trend, TunerTrend.none);
        sound(82, pluckHz(off(a.hz, -20), glide: 25), rms: fading, after: 30);
        expect(m.reading!.trend, TunerTrend.none, reason: 'same pitch, at the same age');
      });

      test('a sudden pluck after silence is compared with the last, held one', () {
        start(mandolin, pin: 'A4');
        silence(3);
        pluck(-15);
        silence(100);
        expect(m.reading!.live, isFalse);
        expect(m.reading!.trend, TunerTrend.none);
        pluck(-22);
        expect(m.reading!.trend, TunerTrend.wrongWay);
      });

      test('within a bowed note: turning while bowing, and stopping', () {
        start(violin, pin: 'A4');
        // -15, then the tuner turned the wrong way over a second, to -25.
        double hz(double t) => off(a.hz, t < 0.5 ? -15 : -15 - 10 * math.min(1.0, (t - 0.5)));
        sound(130, hz); // 1.4 s: still turning
        expect(m.reading!.trend, TunerTrend.wrongWay);
        sound(100, hz, after: 130); // held at -25 past the comparison interval
        expect(m.reading!.trend, TunerTrend.none, reason: 'the turning stopped');
      });

      test('a bow that starts flat and settles is not "too far", and closing in is not red',
          () {
        start(violin, pin: 'D4');
        // The session's D at 58.9 s: the bow's scrape a little flat, then
        // +8¢ and falling towards the target, as the tuner is turned.
        sound(200, (double t) => off(d.hz, t < 0.15 ? -4 : 8 - 2 * math.min(1.0, t)));
        expect(m.reading!.trend, isNot(TunerTrend.overshot));
        expect(m.reading!.trend, isNot(TunerTrend.wrongWay));
      });

      test('no trend within a bow\'s wobble of the target', () {
        start(violin, pin: 'G3');
        final g = violin.strings[0];
        // The session's G at 137 s: drifting from -1 to -6 in one bow.
        sound(200, (double t) => off(g.hz, t < 1.2 ? -1 : -1 - 5 * math.min(1.0, (t - 1.2) / 0.5)));
        expect(m.reading!.cents, lessThan(-4));
        expect(m.reading!.trend, TunerTrend.none);
      });

      test('the same drift in a fading pluck is its glide, not a turn', () {
        start(mandolin, pin: 'A4');
        silence(3);
        // Falling 10¢ over a second, fading as a pluck does.
        sound(150, (double t) => off(a.hz, -15 - 10 * math.min(1.0, t)), rms: fading);
        expect(m.reading!.trend, TunerTrend.none);
      });

      test('a move to another string forgets the last one', () {
        start(violin);
        sound(40, off(d.hz, -20));
        silence(50);
        sound(100, off(a.hz, -10));
        expect(m.reading!.string.name, 'A4');
        expect(m.reading!.trend, TunerTrend.none);
      });
    });
  });
}

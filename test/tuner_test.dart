import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:string_tuner/string_tuner.dart';
import 'package:violin_practice_companion/debug/screenshot_mode.dart';
import 'package:violin_practice_companion/screens/tuner_screen.dart';
import 'package:violin_practice_companion/ui/stringlings/mandolin_headstock.dart';
import 'package:violin_practice_companion/services/instrument_setting.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/tuner_input.dart';
import 'package:violin_practice_companion/services/tuner_model.dart';
import 'package:violin_practice_companion/services/tuner_recording.dart';
import 'package:violin_practice_companion/ui/stringlings/stringling_climber.dart';

/// Frames every ~10.7 ms (a 512-sample hop at 48 kHz), from [ms] onwards.
TunerFrame frame(int i, double? hz, {double clarity = 0.97, double rms = 0.05}) =>
    TunerFrame(Duration(microseconds: (i * 512 * 1e6 / 48000).round()),
        hz == null ? null : PitchEstimate(hz: hz, clarity: clarity, rms: rms));

double off(double hz, double cents) => hz * math.pow(2, cents / 1200);

class FakeTunerInput implements TunerInputBase {
  FakeTunerInput({this.deny = false});
  final bool deny;
  StreamController<TunerFrame>? ctl;
  ({double minHz, double maxHz})? range;
  int starts = 0;

  @override
  bool get isSupported => true;

  @override
  Future<Stream<TunerFrame>> start({required double minHz, required double maxHz}) async {
    starts++;
    if (deny) throw const TunerMicDenied();
    ctl?.close(); // not awaited, as in TunerInput.stop
    range = (minHz: minHz, maxHz: maxHz);
    ctl = StreamController<TunerFrame>();
    return ctl!.stream;
  }

  @override
  Future<void> stop() async {
    ctl?.close();
    ctl = null;
  }

  @override
  Future<void> dispose() => stop();

  @override
  set onPcm(void Function(Uint8List pcm)? f) {}
}

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

    // A pluck: sharp by [glide] at the start, falling back as it fades.
    double Function(double) pluckHz(double hz, {double glide = 0}) =>
        (t) => off(hz, glide * math.exp(-t / 0.45));
    double fading(double t) => 0.2 * math.exp(-t / 0.9);

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

  group('CelebrationClock', () {
    void run(CelebrationClock c, double secs, {double? cents, bool steady = true}) {
      for (var t = 0.0; t < secs; t += 1 / 60) {
        c.update(1 / 60, cents: cents, steady: steady, inTune: steady && cents != null && cents.abs() <= 3);
      }
    }

    test('nothing on opening in tune, or after a climb', () {
      final c = CelebrationClock();
      run(c, 2, cents: 0);
      expect(c.since, isNull);
      run(c, 1, cents: -20, steady: false); // climbing past, out of tune
      run(c, 1, cents: 0);
      expect(c.since, isNull);
    });

    test('earned by being out of tune; lasts 3 s and fades', () {
      final c = CelebrationClock();
      run(c, 0.5, cents: -20);
      run(c, 1, cents: 0);
      expect(c.since, closeTo(1, 0.05));
      expect(c.fade, 1);
      run(c, 1.7, cents: 0);
      expect(c.fade, inExclusiveRange(0, 1), reason: 'fading in the last 0.6 s');
      run(c, 0.5, cents: 0);
      expect(c.fade, 0);
    });

    test('a small wobble or a brush out of tune does not go again', () {
      final c = CelebrationClock();
      run(c, 0.5, cents: -20);
      run(c, 4, cents: 0);
      run(c, 0.3, cents: 5); // out of the zone, under 6 cents
      run(c, 0.5, cents: 0);
      expect(c.since, isNull);
      run(c, 0.2, cents: 20); // past 6 cents, but not for a third of a second
      run(c, 0.5, cents: 0);
      expect(c.since, isNull);
    });
  });

  group('StringlingClimber party', () {
    const rungs = [
      ClimberRung(letter: 'G', color: Colors.green),
      ClimberRung(letter: 'D', color: Colors.blue),
      ClimberRung(letter: 'A', color: Colors.red),
      ClimberRung(letter: 'E', color: Colors.amber),
    ];
    Future<void> show(WidgetTester tester, double? cents, {bool party = true}) => tester.pumpWidget(
        MaterialApp(
            home: SizedBox(
                width: 351,
                height: 480,
                child: StringlingClimber(rungs: rungs, target: 2, cents: cents, party: party))));

    testWidgets('the parade comes, dances, and leaves either way, without a hitch', (tester) async {
      await show(tester, -20);
      await tester.pump(const Duration(seconds: 1));
      await show(tester, 0); // earned: in they march
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50)); // in, dancing, waving off
      }
      await show(tester, -20);
      await tester.pump(const Duration(seconds: 1));
      await show(tester, 0);
      await tester.pump(const Duration(seconds: 1)); // marching in
      await show(tester, 25); // out of tune: they scurry
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('TunerScreen', () {
    Future<FakeTunerInput> pumpTuner(WidgetTester tester,
        {bool deny = false, bool mandolin = false, bool auto = false, bool record = false}) async {
      SharedPreferences.setMockInitialValues({
        if (mandolin) instrumentSetKey: InstrumentSet.violinAndMandolin.name,
        if (auto) tunerAutoStringKey: true,
        if (record) tunerRecordSessionsKey: true,
      });
      final sp = await SharedPreferences.getInstance();
      final fake = FakeTunerInput(deny: deny);
      tester.view.physicalSize = const Size(375, 667) * 3; // iPhone SE
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          tunerInputFactoryProvider.overrideWithValue(() => fake),
        ],
        child: const MaterialApp(home: TunerScreen()),
      ));
      await tester.pump();
      return fake;
    }

    Future<void> listen(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('tuner_mode_tune')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    // The microphone's clock runs on across notes; each one after a pause
    // long enough to end the last (TunerModel.noteGap).
    var clock = 0;
    Future<void> play(WidgetTester tester, FakeTunerInput fake, double hz, {int n = 80}) async {
      for (var i = 0; i < 45; i++) {
        fake.ctl!.add(frame(clock++, null));
      }
      for (var i = 0; i < n; i++) {
        fake.ctl!.add(frame(clock++, hz));
      }
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('tuner_settings')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the sheet slides up
    }

    // Empty when Play mode's hint stands in for the status line.
    String status(WidgetTester tester) {
      final f = find.byKey(const ValueKey('tuner_status'));
      return f.evaluate().isEmpty ? '' : tester.widget<Text>(f).data!;
    }

    StringlingClimber climber(WidgetTester tester) =>
        tester.widget<StringlingClimber>(find.byKey(const ValueKey('tuner_climber')));
    // No figures on screen: what the stringling is told.
    double? cents(WidgetTester tester) => climber(tester).cents;

    testWidgets('opens in play mode with the microphone off', (tester) async {
      final fake = await pumpTuner(tester);
      expect(fake.starts, 0);
      expect(find.byKey(const ValueKey('tuner_mode_tune')), findsOneWidget);
      expect(find.text('flat'), findsOneWidget);
      expect(find.text('sharp'), findsOneWidget);
      expect(find.text('Slide the dot to make it squirm'), findsOneWidget);
      expect(status(tester), '');
      expect(cents(tester), 0);
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Ready to'), findsOneWidget);
      expect(find.textContaining('Hz'), findsNothing, reason: 'the frequencies are in settings');
    });

    testWidgets('holding the dot makes it squirm; letting go springs back to happy', (tester) async {
      await pumpTuner(tester);
      final box = tester.getRect(find.byKey(const ValueKey('tuner_slider')));
      Offset at(double f) => Offset(box.left + box.width * f, box.center.dy);

      final g = await tester.startGesture(at(0.3));
      await tester.pump(const Duration(milliseconds: 150)); // past the press delay
      expect(status(tester), 'Flat · turn the fine tuner clockwise');
      expect(cents(tester), lessThan(0));
      for (var f = 0.3; f <= 0.7; f += 0.05) {
        await g.moveTo(at(f));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(status(tester), 'Sharp · turn the fine tuner anti-clockwise');
      await g.moveTo(at(1.0));
      await tester.pump();
      expect(status(tester), 'Very sharp · the peg needs a turn down');
      await tester.pump(const Duration(seconds: 1)); // squirming while held
      expect(status(tester), 'Very sharp · the peg needs a turn down', reason: 'held, it stays');

      await g.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(cents(tester), 0);
      expect(status(tester), '');

      // A plain tap also springs back.
      await tester.tapAt(at(0.1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(cents(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('held at the sharp end, it flings itself up a string (and only up)', (tester) async {
      await pumpTuner(tester);
      final box = tester.getRect(find.byKey(const ValueKey('tuner_slider')));
      Offset at(double f) => Offset(box.left + box.width * f, box.center.dy);
      expect(climber(tester).target, 2, reason: 'opens on A');
      final g = await tester.startGesture(at(0.5));
      await g.moveTo(at(1.0));
      await tester.pump(const Duration(seconds: 1));
      expect(climber(tester).target, 2, reason: 'not yet');
      await tester.pump(const Duration(seconds: 1));
      expect(climber(tester).target, 3, reason: 'flung up to E');
      expect(climber(tester).stretches, 1);
      await tester.pump(const Duration(seconds: 8));
      expect(climber(tester).target, 3, reason: 'E is the top: it only strains');
      expect(climber(tester).stretches, 1);
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(climber(tester).target, 3, reason: 'it stays on the string it reached');
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('held at the flat end, it falls a string (and only down)', (tester) async {
      await pumpTuner(tester);
      int target() => climber(tester).target;
      final box = tester.getRect(find.byKey(const ValueKey('tuner_slider')));
      Offset at(double f) => Offset(box.left + box.width * f, box.center.dy);
      expect(target(), 2, reason: 'opens on A');

      // Briefly at the flat end: not yet.
      final g = await tester.startGesture(at(0.5));
      await g.moveTo(at(0.0));
      await tester.pump(const Duration(seconds: 1));
      expect(target(), 2);
      await tester.pump(const Duration(seconds: 1));
      expect(target(), 1, reason: 'fell to D');
      expect(cents(tester), -50, reason: 'really flat on D');
      await tester.pump(const Duration(seconds: 6));
      expect(target(), 0, reason: 'kept holding: fell to G, and stops there');
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(target(), 0, reason: 'it stays on the string it fell to');
      expect(cents(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Tune starts listening; a flat G says turn clockwise', (tester) async {
      final fake = await pumpTuner(tester, auto: true);
      await listen(tester);
      expect(fake.starts, 1);
      expect(find.byKey(const ValueKey('tuner_mode_play')), findsOneWidget);
      expect(find.text('Slide the dot to make it squirm'), findsNothing);
      expect(status(tester), 'Play a string');
      expect(fake.range!.minHz, closeTo(195.56 / 1.5, 0.01));

      await play(tester, fake, off(195.556, -30));
      expect(cents(tester), closeTo(-30, 0.5));
      expect(status(tester), 'Flat · turn the fine tuner clockwise');
      await tester.pump(const Duration(seconds: 1)); // climbs down to G
      expect(tester.takeException(), isNull);
    });

    testWidgets('in tune, then Play Mode stops listening', (tester) async {
      final fake = await pumpTuner(tester);
      await listen(tester);
      await play(tester, fake, 440.5);
      expect(status(tester), 'In tune!');
      await tester.pump(const Duration(seconds: 2)); // sparkles
      await tester.tap(find.byKey(const ValueKey('tuner_mode_play')));
      await tester.pump();
      expect(find.byKey(const ValueKey('tuner_play_hint')), findsOneWidget);
      expect(fake.ctl, isNull, reason: 'the microphone stopped');
    });

    testWidgets('the last note\'s pose and advice stay after it stops', (tester) async {
      final fake = await pumpTuner(tester);
      await listen(tester);
      await play(tester, fake, off(440, -20));
      for (var i = 0; i < 300; i++) {
        fake.ctl!.add(frame(clock++, null)); // ~3 s of quiet
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(cents(tester), closeTo(-20, 0.5), reason: 'still hanging flat');
      expect(status(tester), 'Flat · turn the fine tuner clockwise');
    });

    testWidgets('says when a turn went the wrong way, and which way to go', (tester) async {
      final fake = await pumpTuner(tester);
      await listen(tester);
      // Each a second long, past the point notes are compared at.
      await play(tester, fake, off(440, -20), n: 100);
      expect(status(tester), 'Flat · turn the fine tuner clockwise');
      expect(climber(tester).wrongWay, isFalse);
      await play(tester, fake, off(440, -30), n: 100);
      expect(status(tester), 'Wrong way! Turn clockwise instead');
      expect(climber(tester).wrongWay, isTrue, reason: 'the arrow pulses red');
      await play(tester, fake, off(440, -12), n: 100);
      expect(status(tester), 'Closer! Keep turning clockwise');
      expect(climber(tester).wrongWay, isFalse);
      await play(tester, fake, off(440, 10), n: 100);
      expect(status(tester), 'Too far! Back a little, anti-clockwise');
      await play(tester, fake, off(440, 1), n: 100);
      expect(status(tester), 'In tune!');
      await tester.pump(const Duration(seconds: 4)); // the celebration
      expect(tester.takeException(), isNull);
    });

    testWidgets('mandolin: a first tap picks the lower string of a pair, the next the upper',
        (tester) async {
      await pumpTuner(tester, mandolin: true);
      await openSettings(tester);
      await tester.tap(find.text('Mandolin'));
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 400));
      MandolinHeadstock head() => tester.widget(find.byKey(const ValueKey('tuner_headstock')));
      StringlingClimber climber() => tester.widget(find.byKey(const ValueKey('tuner_climber')));

      await tester.tap(find.byKey(const ValueKey('tuner_string_G')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(climber().pickedLine, 0);
      expect(climber().pickedLabel, 'outside', reason: "G's lower rule is the string on the neck's edge");
      expect(head().course, 'G');
      expect(head().which, MandolinString.outer);

      await tester.tap(find.byKey(const ValueKey('tuner_string_G')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(climber().pickedLine, 1);
      expect(head().which, MandolinString.inner);

      // A's lower rule is its inside string: the rules run as across the neck.
      await tester.tap(find.byKey(const ValueKey('tuner_string_A')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(climber().pickedLine, 0);
      expect(climber().pickedLabel, 'inside');
      expect(head().which, MandolinString.inner);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('mandolin: wrong way, in tuner words', (tester) async {
      final fake = await pumpTuner(tester, mandolin: true);
      await openSettings(tester);
      await tester.tap(find.text('Mandolin'));
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 400));
      await listen(tester);
      await play(tester, fake, off(440, 15), n: 100);
      expect(status(tester), 'Sharp · roll the top toward the headstock end');
      await play(tester, fake, off(440, 24), n: 100);
      expect(status(tester), 'Wrong way! Roll the top toward the headstock end');
    });

    testWidgets('without TUNER_RECORDING a long press on the title does nothing',
        (tester) async {
      await pumpTuner(tester, record: true);
      expect(find.byKey(const ValueKey('tuner_rec')), findsNothing,
          reason: 'a saved switch from a recording build is ignored');
      await tester.longPress(find.byKey(const ValueKey('tuner_title')));
      await tester.pump();
      expect(find.byKey(const ValueKey('tuner_rec')), findsNothing);
      expect(find.byKey(const ValueKey('tuner_mark')), findsNothing);
    }, skip: kTunerRecording);

    // Run with: flutter test --dart-define=TUNER_RECORDING=true test/tuner_test.dart
    testWidgets('a long press on the title switches the session recording', (tester) async {
      final fake = await pumpTuner(tester);
      expect(find.byKey(const ValueKey('tuner_rec')), findsNothing);
      expect(find.byKey(const ValueKey('tuner_mark')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('tuner_title')));
      await tester.pump();
      expect(find.byKey(const ValueKey('tuner_rec')), findsOneWidget);
      expect(find.byKey(const ValueKey('tuner_mark')), findsOneWidget);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool(tunerRecordSessionsKey), isTrue);
      expect(find.text('Recording tuning sessions on this phone'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // the note clears
      // No documents directory in a widget test: the tuner still listens.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('tuner_mode_tune')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(fake.ctl, isNotNull, reason: 'listening without a recording');
      await play(tester, fake, 440);
      expect(status(tester), 'In tune!');
      await tester.longPress(find.byKey(const ValueKey('tuner_title')));
      await tester.pump();
      expect(find.byKey(const ValueKey('tuner_rec')), findsNothing);
      expect(sp.getBool(tunerRecordSessionsKey), isFalse);
      await tester.pump(const Duration(seconds: 3));
    }, skip: !kTunerRecording);

    testWidgets('A = 442 lives in the settings sheet, is saved and retargets', (tester) async {
      final fake = await pumpTuner(tester);
      expect(find.text('A = 442'), findsNothing);
      await listen(tester);
      await openSettings(tester);
      String hz() => tester.widget<Text>(find.byKey(const ValueKey('tuner_string_hz'))).data!;
      expect(hz(), contains('A4 440.00'));
      await tester.tap(find.text('A = 442'));
      await tester.pump();
      expect(hz(), contains('A4 442.00'), reason: 'the frequencies follow A');
      await tester.pump(const Duration(milliseconds: 20));
      expect(fake.starts, 2, reason: 'the range moved, so the mic restarts');
      await play(tester, fake, 442);
      expect(status(tester), 'In tune!');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getInt(tunerA4Key), 442);
    });

    testWidgets('mandolin only with the mandolin instrument set', (tester) async {
      await pumpTuner(tester);
      await openSettings(tester);
      expect(find.text('Mandolin'), findsNothing);
    });

    testWidgets('mandolin is equal-tempered, and has no fine-tuner advice', (tester) async {
      final fake = await pumpTuner(tester, mandolin: true, auto: true);
      await openSettings(tester);
      await tester.tap(find.text('Mandolin'));
      await tester.pump();
      await tester.tapAt(const Offset(10, 10)); // close the sheet
      await tester.pump(const Duration(milliseconds: 400));
      await listen(tester);
      await play(tester, fake, 196.0); // equal-tempered G: in tune here
      expect(status(tester), 'In tune!');
      await play(tester, fake, off(196.0, -15));
      expect(status(tester), 'Flat · roll the top toward the headstock end');
    });

    testWidgets('a picked string is measured against even off-string', (tester) async {
      final fake = await pumpTuner(tester);
      await tester.tap(find.byKey(const ValueKey('tuner_string_E')));
      await tester.pump();
      await listen(tester);
      await play(tester, fake, off(660, -45));
      expect(cents(tester), closeTo(-45, 0.5));
    });

    testWidgets('opens on A, and a tapped string is the one tuned', (tester) async {
      final fake = await pumpTuner(tester);
      StringlingClimber climber() => tester.widget<StringlingClimber>(find.byKey(const ValueKey('tuner_climber')));
      expect(climber().picked, 2);
      await listen(tester);
      await play(tester, fake, 440);
      expect(status(tester), 'In tune!');
      await play(tester, fake, 196.0); // a G, but A is picked
      expect(climber().target, 2);
      await tester.tap(find.byKey(const ValueKey('tuner_string_D')));
      await tester.pump();
      expect(climber().picked, 1);
      await play(tester, fake, 293.66);
      expect(status(tester), 'In tune!');
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Choose | Sense under Tune: following the string played, saved', (tester) async {
      final fake = await pumpTuner(tester);
      await openSettings(tester);
      expect(find.text('Follow the string I play'), findsNothing, reason: 'one place only');
      await tester.tapAt(const Offset(10, 10)); // close the sheet
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('tuner_sense')));
      await tester.pump();
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool(tunerAutoStringKey), isTrue);
      expect(find.text('Sense: following the string you play'), findsOneWidget);
      expect(climber(tester).picked, isNull);
      await listen(tester);
      await play(tester, fake, 195.556);
      expect(climber(tester).target, 0, reason: 'followed to G');
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('tuner_note')), findsNothing, reason: 'the note goes');
      expect(status(tester), 'In tune!');
      await tester.tap(find.byKey(const ValueKey('tuner_choose')));
      await tester.pump();
      expect(sp.getBool(tunerAutoStringKey), isFalse);
      expect(climber(tester).picked, 0, reason: 'chooses the string it is on');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('sharp on E its head comes up between the pills; flat on G its feet stay in',
        (tester) async {
      await pumpTuner(tester);
      final card = tester.getRect(find.byKey(const ValueKey('tuner_climber')));
      Rect onScreen(Rect r) => r.shift(card.topLeft);
      final play = tester.getRect(find.byKey(const ValueKey('tuner_mode_play')));
      final tune = tester.getRect(find.byKey(const ValueKey('tuner_mode_tune')));
      final sense = tester.getRect(find.byKey(const ValueKey('tuner_sense')));
      final choose = tester.getRect(find.byKey(const ValueKey('tuner_choose')));
      final sharpE = onScreen(StringlingClimber.bodyAt(card.size, 4, 3, 50));
      expect(sharpE.top, greaterThanOrEqualTo(card.top));
      // Side to side it sits between the pills, but the test font's square
      // glyphs make them far wider than on a phone, so that is checked on
      // the simulator; here, only that it is below the pills' tops and left
      // of the Tune pill's middle (it comes up nearer the left one).
      expect(sharpE.center.dx, lessThan(tune.center.dx));
      expect(sharpE.center.dx, greaterThan(play.center.dx));
      // The E string's own rule sits under the corner controls.
      final restE = onScreen(StringlingClimber.bodyAt(card.size, 4, 3, 0));
      final ry = restE.height / 2.05, ruleE = restE.top + ry * 1.3;
      for (final r in [play, tune, sense, choose]) {
        expect(ruleE, greaterThan(r.bottom), reason: 'E rule at $ruleE under $r');
      }
      final flatG = StringlingClimber.bodyAt(card.size, 4, 0, -50);
      expect(flatG.bottom, lessThan(card.height));
      expect(card.height - flatG.bottom, lessThan(24), reason: 'just enough room below G');
      // Out of tune a little, it is already well off the string.
      final rest = StringlingClimber.bodyAt(card.size, 4, 2, 0).top;
      final tenFlat = StringlingClimber.bodyAt(card.size, 4, 2, -10).top;
      final fiftyFlat = StringlingClimber.bodyAt(card.size, 4, 2, -50).top;
      expect((tenFlat - rest) / (fiftyFlat - rest), greaterThan(0.4));
    });

    testWidgets('microphone refused, then back to playing', (tester) async {
      await pumpTuner(tester, deny: true);
      await listen(tester);
      expect(find.byKey(const ValueKey('tuner_mic_denied')), findsOneWidget);
      await tester.tap(find.text('Back to playing'));
      await tester.pump();
      expect(find.byKey(const ValueKey('tuner_play_hint')), findsOneWidget);
    });
  });
}

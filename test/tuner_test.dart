import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:string_tuner/string_tuner.dart';
import 'package:violin_practice_companion/screens/tuner_screen.dart';
import 'package:violin_practice_companion/services/instrument_setting.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/tuner_input.dart';
import 'package:violin_practice_companion/services/tuner_model.dart';
import 'package:violin_practice_companion/ui/stringlings/stringling_climber.dart';

/// Frames every ~10.7 ms (a 512-sample hop at 48 kHz), from [ms] onwards.
TunerFrame frame(int i, double? hz, {double clarity = 0.97, int startMs = 0}) =>
    TunerFrame(Duration(microseconds: startMs * 1000 + (i * 512 * 1e6 / 48000).round()),
        hz == null ? null : PitchEstimate(hz: hz, clarity: clarity, rms: 0.05));

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
}

void main() {
  group('TunerModel', () {
    final violin = InstrumentTuning.violin();
    final a = violin.strings[2], d = violin.strings[1];

    test('steady flat A reads flat on A', () {
      final m = TunerModel(violin);
      for (var i = 0; i < 20; i++) {
        m.add(frame(i, off(a.hz, -12)));
      }
      expect(m.reading!.string.name, 'A4');
      expect(m.reading!.cents, closeTo(-12, 0.01));
      expect(m.reading!.live, isTrue);
    });

    test('ignores unclear frames and a single wild one', () {
      final m = TunerModel(violin);
      for (var i = 0; i < 10; i++) {
        m.add(frame(i, off(a.hz, 4)));
      }
      m.add(frame(10, a.hz * 2)); // an octave blip
      m.add(frame(11, 300, clarity: 0.4)); // noise
      expect(m.reading!.cents, closeTo(4, 0.01));
    });

    test('holds through a short gap, then goes idle', () {
      final m = TunerModel(violin);
      for (var i = 0; i < 10; i++) {
        m.add(frame(i, a.hz));
      }
      m.add(frame(30, null)); // ~210 ms later: a dropout, still live
      expect(m.reading!.live, isTrue);
      m.add(frame(60, null)); // ~540 ms later: a gap, held
      expect(m.reading, isNotNull);
      expect(m.reading!.live, isFalse);
      m.add(frame(200, null)); // ~2 s
      expect(m.reading, isNull);
    });

    test('pinned string measures everything against it', () {
      final m = TunerModel(violin)..pinned = 'D4';
      for (var i = 0; i < 10; i++) {
        m.add(frame(i, a.hz));
      }
      expect(m.reading!.string.name, 'D4');
      expect(m.reading!.cents, closeTo(701.96, 0.01)); // a pure fifth up
    });

    test('follows a move to another string, not a brush of it', () {
      final m = TunerModel(violin);
      var i = 0;
      for (; i < 20; i++) {
        m.add(frame(i, d.hz));
      }
      for (var k = 0; k < 6; k++) {
        m.add(frame(i++, a.hz));
      }
      expect(m.reading!.string.name, 'D4');
      for (var k = 0; k < 20; k++) {
        m.add(frame(i++, a.hz));
      }
      expect(m.reading!.string.name, 'A4');
      expect(m.reading!.cents, closeTo(0, 0.01));
    });

    test('A = 442 moves the targets', () {
      final m = TunerModel(InstrumentTuning.violin(a4: 442));
      for (var i = 0; i < 10; i++) {
        m.add(frame(i, 440));
      }
      expect(m.reading!.cents, closeTo(-7.85, 0.01));
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
        {bool deny = false, bool mandolin = false, bool auto = false}) async {
      SharedPreferences.setMockInitialValues({
        if (mandolin) instrumentSetKey: InstrumentSet.violinAndMandolin.name,
        if (auto) tunerAutoStringKey: true,
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

    Future<void> play(WidgetTester tester, FakeTunerInput fake, double hz, {int n = 30}) async {
      for (var i = 0; i < n; i++) {
        fake.ctl!.add(frame(i, hz));
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
      expect(status(tester), 'Flat · tighten the tuner');
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

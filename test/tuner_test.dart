import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pitch_tuner/pitch_tuner.dart';
import 'package:violin_practice_companion/debug/screenshot_mode.dart';
import 'package:violin_practice_companion/screens/chromatic_tuner_screen.dart';
import 'package:violin_practice_companion/screens/tuner_screen.dart';
import 'package:violin_practice_companion/ui/stringlings/mandolin_headstock.dart';
import 'package:violin_practice_companion/services/drone_player.dart';
import 'package:violin_practice_companion/models/app_edition.dart';
import 'package:violin_practice_companion/services/instrument_setting.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/tuner_input.dart';
import 'package:violin_practice_companion/services/tuner_advice.dart';
import 'package:violin_practice_companion/services/tuner_recording.dart';
import 'package:violin_practice_companion/ui/stringlings/stringling_climber.dart';

import 'support/plucked_pair.dart';


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

  double? probe;
  @override
  set probeHz(double? hz) => probe = hz;
}

class FakeDronePlayer implements DronePlayerBase {
  /// Every pitch asked for, in order.
  final played = <double>[];
  double? sounding;
  int stops = 0;
  bool disposed = false;

  @override
  Future<void> play(double hz) async {
    played.add(hz);
    sounding = hz;
  }

  @override
  Future<void> stop() async {
    stops++;
    sounding = null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    sounding = null;
  }
}

void main() {
  group('CelebrationClock', () {
    void run(CelebrationClock c, double secs, {double? cents, bool steady = true, bool? earned}) {
      for (var t = 0.0; t < secs; t += 1 / 60) {
        c.update(1 / 60,
            cents: cents, steady: steady, inTune: steady && cents != null && cents.abs() <= 3, earned: earned);
      }
    }

    test('with the tuner counting, it waits until the run has earned it', () {
      final c = CelebrationClock();
      run(c, 0.5, cents: -20, earned: false);
      run(c, 1, cents: 0, earned: false); // the first in-tune pluck
      expect(c.since, isNull);
      run(c, 1, cents: 1, earned: false); // the second
      expect(c.since, isNull);
      run(c, 1, cents: 0, earned: true); // the third
      expect(c.since, closeTo(1, 0.05));
    });

    test('a run of in-tune plucks earns it even when the string was never far out', () {
      final c = CelebrationClock();
      run(c, 1, cents: -4, earned: false); // 4 cents flat: not "really out"
      run(c, 2, cents: 0, earned: false); // two in tune
      expect(c.since, isNull);
      run(c, 1, cents: 0, earned: true); // the third
      expect(c.since, closeTo(1, 0.05));
    });

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
    late FakeDronePlayer drone;

    Future<FakeTunerInput> pumpTuner(WidgetTester tester,
        {bool deny = false, bool mandolin = false, bool auto = false, bool record = false}) async {
      SharedPreferences.setMockInitialValues({
        if (mandolin) instrumentSetKey: InstrumentSet.mandolin.name,
        if (auto) tunerAutoStringKey: true,
        if (record) tunerRecordSessionsKey: true,
      });
      final sp = await SharedPreferences.getInstance();
      final fake = FakeTunerInput(deny: deny);
      drone = FakeDronePlayer();
      tester.view.physicalSize = const Size(375, 667) * 3; // iPhone SE
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          tunerInputFactoryProvider.overrideWithValue(() => fake),
          dronePlayerFactoryProvider.overrideWithValue(() => drone),
          if (mandolin) appEditionProvider.overrideWithValue(AppEdition.mandolin),
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

    testWidgets('the celebration waits for three in-tune notes in a row', (tester) async {
      final fake = await pumpTuner(tester);
      await listen(tester);
      await play(tester, fake, off(440, -20));
      expect(climber(tester).inTuneRun, 0);
      await play(tester, fake, 440.5);
      expect(status(tester), 'In tune! Play it again to check');
      expect(climber(tester).inTuneRun, 1);
      await play(tester, fake, 440.5);
      expect(status(tester), 'In tune! Once more');
      expect(climber(tester).inTuneRun, 2);
      await play(tester, fake, 440.5);
      expect(status(tester), 'In tune!');
      expect(climber(tester).inTuneRun, 3, reason: 'now it celebrates');
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('in tune, then Play Mode stops listening', (tester) async {
      final fake = await pumpTuner(tester);
      await listen(tester);
      await play(tester, fake, 440.5);
      expect(status(tester), startsWith('In tune!'));
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
      expect(status(tester), 'Closer! Another half turn clockwise', reason: 'close: half a turn only');
      expect(climber(tester).wrongWay, isFalse);
      await play(tester, fake, off(440, 10), n: 100);
      expect(status(tester), 'Too far! Half a turn back, anti-clockwise');
      await play(tester, fake, off(440, 1), n: 100);
      expect(status(tester), startsWith('In tune!'));
      await tester.pump(const Duration(seconds: 4)); // the celebration
      expect(tester.takeException(), isNull);
    });

    testWidgets('says Listening while a note settles, keeping the last pose', (tester) async {
      final fake = await pumpTuner(tester);
      await listen(tester);
      await play(tester, fake, off(440, -15), n: 100);
      expect(status(tester), 'Flat · turn the fine tuner clockwise');
      final before = cents(tester);
      await play(tester, fake, off(440, 15), n: 20); // 0.2 s of a new note
      expect(status(tester), 'Listening…');
      expect(cents(tester), before, reason: 'the last pose holds');
      for (var i = 0; i < 60; i++) {
        fake.ctl!.add(frame(clock++, off(440, 15)));
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(status(tester), startsWith('Sharp'));
    });

    testWidgets('mandolin: a first tap picks the lower string of a pair, the next the upper',
        (tester) async {
      await pumpTuner(tester, mandolin: true);
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

    // Both strings of a course, plucked: through the real tracker, probing
    // the frequency the screen asked for, so the frames carry their bands.
    Future<void> pluckPair(WidgetTester tester, FakeTunerInput fake, double hz, double cents,
        {double second = 1}) async {
      for (var i = 0; i < 45; i++) {
        fake.ctl!.add(frame(clock++, null));
      }
      final tracker = PitchTracker(
          YinDetector(sampleRate: pluckRate.toDouble(), minHz: fake.range!.minHz, maxHz: fake.range!.maxHz))
        ..probeHz = fake.probe;
      for (final r in tracker.addSamples(pluck(hz, cents, second: second))) {
        fake.ctl!.add(TunerFrame(frame(clock++, null).at, r.pitch, r.bands));
      }
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('mandolin: a third tap is both strings together, judged by their beats', (tester) async {
      final fake = await pumpTuner(tester, mandolin: true);
      await listen(tester);
      StringlingClimber climber() => tester.widget(find.byKey(const ValueKey('tuner_climber')));
      MandolinHeadstock head() => tester.widget(find.byKey(const ValueKey('tuner_headstock')));
      Future<void> tapA() async {
        await tester.tap(find.byKey(const ValueKey('tuner_string_A')));
        await tester.pump(const Duration(milliseconds: 600));
      }

      await tapA(); // already A: this is its other string
      await tapA();
      if (climber().pickedLine != 2) await tapA();
      expect(climber().pickedLine, 2);
      expect(climber().pickedLabel, 'both');
      expect(head().which, isNull, reason: 'both buttons, not one');
      expect(fake.probe, closeTo(440, 0.01), reason: 'the A course is listened to for beats');
      await tester.pump(const Duration(seconds: 3)); // the "A: both strings" note passes
      expect(status(tester), unisonPrompt);

      await pluckPair(tester, fake, 440, 0);
      expect(status(tester), 'Together! Both strings in tune');
      expect(climber().pickedLine, 2, reason: 'passed: stays on both');
      expect(climber().inTuneRun, TunerModel.celebrateAfter, reason: 'the party is for the pair');
      expect(climber().inTune, isTrue);

      await pluckPair(tester, fake, 440, 8);
      expect(climber().inTuneRun, 0, reason: 'beating: no party');
      expect(status(tester), startsWith('They beat, '));
      expect(status(tester), endsWith('¢ apart · tap to tune each'));
      expect(climber().pickedLine, 2, reason: 'failed: stays on both until the player taps');

      await tester.tap(find.byKey(const ValueKey('tuner_string_A'))); // the player says
      await tester.pump(const Duration(milliseconds: 600));
      expect(climber().pickedLine, 0);
      expect(climber().pickedLabel, 'inside');
      await tester.pump(const Duration(seconds: 3)); // "A: the inside string" passes
      await pluckPair(tester, fake, 440, 0, second: 0); // the first string: the verdict gives way
      expect(status(tester), startsWith('In tune!'));
      expect(climber().inTuneRun, 0, reason: "on a mandolin one string's run is no party");
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('mandolin: wrong way, in tuner words', (tester) async {
      final fake = await pumpTuner(tester, mandolin: true);
      await listen(tester);
      await play(tester, fake, off(440, 15), n: 100);
      expect(status(tester), 'Sharp · roll top toward the headstock end');
      await play(tester, fake, off(440, 24), n: 100);
      expect(status(tester), 'Wrong way! Roll top toward the headstock end');
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
      expect(status(tester), startsWith('In tune!'));
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
      expect(status(tester), startsWith('In tune!'));
      final sp = await SharedPreferences.getInstance();
      expect(sp.getInt(tunerA4Key), 442);
    });

    testWidgets('the tuner tunes the instrument set up, with no switch of its own',
        (tester) async {
      await pumpTuner(tester);
      await openSettings(tester);
      expect(find.text('Mandolin'), findsNothing);
    });

    testWidgets('mandolin is equal-tempered, and has no fine-tuner advice', (tester) async {
      final fake = await pumpTuner(tester, mandolin: true, auto: true);
      await listen(tester);
      await play(tester, fake, 196.0); // equal-tempered G: in tune here
      expect(status(tester), startsWith('In tune!'));
      await play(tester, fake, off(196.0, -15));
      expect(status(tester), 'Flat · roll top toward the headstock end');
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
      expect(status(tester), startsWith('In tune!'));
      await play(tester, fake, 196.0); // a G, but A is picked
      expect(climber().target, 2);
      await tester.tap(find.byKey(const ValueKey('tuner_string_D')));
      await tester.pump();
      expect(climber().picked, 1);
      await play(tester, fake, 293.66);
      expect(status(tester), startsWith('In tune!'));
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
      expect(status(tester), startsWith('In tune!'));
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
      final droneButton = tester.getRect(find.byKey(const ValueKey('tuner_drone')));
      for (final r in [play, tune, sense, choose, droneButton]) {
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

    Future<void> toggleDrone(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('tuner_drone')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    group('drone', () {
      testWidgets('on: the microphone stops and the picked string sounds', (tester) async {
        final fake = await pumpTuner(tester);
        await listen(tester);
        expect(fake.ctl, isNotNull);
        await toggleDrone(tester);
        expect(fake.ctl, isNull, reason: 'the mic would only hear the drone');
        expect(drone.sounding, closeTo(440, 0.01));
        expect(status(tester), 'Tune by ear to the drone');
        expect(cents(tester), isNull, reason: 'the stringling rests');
        // Neither mode pill is lit while it sounds.
        bool lit(String key) => tester
            .widget<Semantics>(find
                .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Semantics))
                .first)
            .properties
            .selected!;
        expect(lit('tuner_mode_tune'), isFalse);
        expect(lit('tuner_mode_play'), isFalse);
      });

      testWidgets('another string tapped sounds that one, in pure fifths', (tester) async {
        await pumpTuner(tester);
        await toggleDrone(tester);
        await tester.tap(find.byKey(const ValueKey('tuner_string_E')));
        await tester.pump();
        expect(drone.sounding, closeTo(660, 0.01));
        await tester.tap(find.byKey(const ValueKey('tuner_string_G')));
        await tester.pump();
        expect(drone.sounding, closeTo(440 * 4 / 9, 0.01));
        await tester.pump(const Duration(seconds: 3)); // the notes clear
      });

      testWidgets('off: back to listening if it was listening', (tester) async {
        final fake = await pumpTuner(tester);
        await listen(tester);
        await toggleDrone(tester);
        expect(fake.starts, 1);
        await toggleDrone(tester);
        expect(drone.sounding, isNull);
        expect(fake.starts, 2);
        expect(fake.ctl, isNotNull, reason: 'listening again');
        await play(tester, fake, 440);
        expect(status(tester), startsWith('In tune!'));
      });

      testWidgets('off: back to Play Mode if it was playing', (tester) async {
        final fake = await pumpTuner(tester);
        await toggleDrone(tester);
        expect(drone.sounding, closeTo(440, 0.01));
        await toggleDrone(tester);
        expect(drone.sounding, isNull);
        expect(fake.starts, 0);
        expect(find.byKey(const ValueKey('tuner_play_hint')), findsOneWidget);
        expect(cents(tester), 0);
      });

      testWidgets('Ready to Tune while it sounds stops it and listens', (tester) async {
        final fake = await pumpTuner(tester);
        await toggleDrone(tester);
        await listen(tester);
        expect(drone.sounding, isNull);
        expect(fake.ctl, isNotNull);
      });

      testWidgets('settings stop it; A = 442 retargets the next drone', (tester) async {
        await pumpTuner(tester);
        await toggleDrone(tester);
        await openSettings(tester);
        expect(drone.sounding, isNull);
        await tester.tap(find.text('A = 442'));
        await tester.pump();
        await tester.tapAt(const Offset(10, 10)); // close the sheet
        await tester.pump(const Duration(milliseconds: 400));
        await toggleDrone(tester);
        expect(drone.sounding, closeTo(442, 0.01));
      });

      testWidgets('in Sense it sounds the string last followed, A at first', (tester) async {
        final fake = await pumpTuner(tester, auto: true);
        await toggleDrone(tester);
        expect(drone.sounding, closeTo(440, 0.01));
        await toggleDrone(tester);
        await listen(tester);
        await play(tester, fake, 293.33);
        await toggleDrone(tester);
        expect(drone.sounding, closeTo(440 * 2 / 3, 0.01), reason: 'followed to D');
      });

      testWidgets('the app going to the background stops it', (tester) async {
        final fake = await pumpTuner(tester);
        await listen(tester);
        await toggleDrone(tester);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(drone.sounding, isNull);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        expect(fake.ctl, isNotNull, reason: 'back to listening, as before the drone');
      });

      testWidgets('leaving the screen releases it', (tester) async {
        await pumpTuner(tester);
        await toggleDrone(tester);
        await tester.pumpWidget(const SizedBox());
        expect(drone.disposed, isTrue);
        expect(drone.sounding, isNull);
      });
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

  group('ChromaticTunerScreen (Windlings, the recorder)', () {
    Future<FakeTunerInput> pumpChromatic(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final sp = await SharedPreferences.getInstance();
      final fake = FakeTunerInput();
      tester.view.physicalSize = const Size(375, 667) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          tunerInputFactoryProvider.overrideWithValue(() => fake),
          appEditionProvider.overrideWithValue(AppEdition.windlings),
        ],
        child: const MaterialApp(home: ChromaticTunerScreen()),
      ));
      await tester.pump();
      return fake;
    }

    var clock = 0;
    Future<void> play(WidgetTester tester, FakeTunerInput fake, double hz) async {
      for (var i = 0; i < 45; i++) {
        fake.ctl!.add(frame(clock++, null));
      }
      for (var i = 0; i < 120; i++) {
        fake.ctl!.add(frame(clock++, hz));
      }
      await tester.pump(const Duration(milliseconds: 50));
    }

    String text(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(ValueKey(key))).data!;

    testWidgets('names the written note: a sounding C5 is C', (tester) async {
      final fake = await pumpChromatic(tester);
      expect(fake.starts, 0, reason: 'the microphone waits for Listen');
      expect(find.byType(StringlingClimber), findsNothing);
      expect(find.byType(MandolinHeadstock), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tuner_listen')));
      await tester.pump();
      expect(fake.starts, 1);
      // The recorder's whole sounding range, C5 to D7, is in the band.
      expect(fake.range!.minHz, lessThan(523));
      expect(fake.range!.maxHz, greaterThan(2350));

      await play(tester, fake, midiToHz(72)); // C5
      expect(text(tester, 'tuner_note'), 'C');
      expect(text(tester, 'tuner_written'), 'C4 as written · sounds C5');
      expect(text(tester, 'tuner_status'), 'In tune');

      await play(tester, fake, off(midiToHz(81), -20)); // A5, 20 cents flat
      expect(text(tester, 'tuner_note'), 'A');
      expect(text(tester, 'tuner_written'), 'A4 as written · sounds A5');
      expect(text(tester, 'tuner_status'), '20 cents flat');

      // No string letters anywhere.
      for (final s in ['G', 'D', 'E']) {
        expect(find.text(s), findsNothing);
      }
      await tester.tap(find.byKey(const ValueKey('tuner_listen')));
      await tester.pump();
    });
  });
}

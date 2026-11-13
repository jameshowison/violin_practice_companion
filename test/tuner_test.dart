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

  group('TunerScreen', () {
    Future<FakeTunerInput> pumpTuner(WidgetTester tester,
        {bool deny = false, bool mandolin = false}) async {
      SharedPreferences.setMockInitialValues({
        if (mandolin) instrumentSetKey: InstrumentSet.violinAndMandolin.name,
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
      await tester.tap(find.byKey(const ValueKey('tuner_ready')));
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

    String status(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('tuner_status'))).data!;

    testWidgets('opens in play mode with the microphone off', (tester) async {
      final fake = await pumpTuner(tester);
      expect(fake.starts, 0);
      expect(find.byKey(const ValueKey('tuner_ready')), findsOneWidget);
      expect(find.text('flat'), findsOneWidget);
      expect(find.text('sharp'), findsOneWidget);
      expect(find.text('Slide the dot to make it squirm'), findsOneWidget);
      expect(status(tester), '');
      expect(find.text('±0¢'), findsOneWidget);
    });

    testWidgets('holding the dot makes it squirm; letting go springs back to happy', (tester) async {
      await pumpTuner(tester);
      String cents() => tester.widget<Text>(find.byKey(const ValueKey('tuner_cents'))).data!;
      final box = tester.getRect(find.byKey(const ValueKey('tuner_slider')));
      Offset at(double f) => Offset(box.left + box.width * f, box.center.dy);

      final g = await tester.startGesture(at(0.3));
      await tester.pump(const Duration(milliseconds: 150)); // past the press delay
      expect(status(tester), 'Flat · turn the fine tuner clockwise');
      expect(cents(), startsWith('−'));
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
      expect(cents(), '±0¢');
      expect(status(tester), '');

      // A plain tap also springs back.
      await tester.tapAt(at(0.1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(cents(), '±0¢');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Ready to tune? starts listening; a flat G says turn clockwise', (tester) async {
      final fake = await pumpTuner(tester);
      await listen(tester);
      expect(fake.starts, 1);
      expect(find.byKey(const ValueKey('tuner_stop')), findsOneWidget);
      expect(find.text('Slide the dot to make it squirm'), findsNothing);
      expect(status(tester), 'Play a string');
      expect(fake.range!.minHz, closeTo(195.56 / 1.5, 0.01));

      await play(tester, fake, off(195.556, -30));
      expect(find.text('−30.0¢'), findsOneWidget);
      expect(status(tester), 'Flat · turn the fine tuner clockwise');
      await tester.pump(const Duration(seconds: 1)); // climbs down to G
      expect(tester.takeException(), isNull);
    });

    testWidgets('in tune, then stop goes back to playing', (tester) async {
      final fake = await pumpTuner(tester);
      await listen(tester);
      await play(tester, fake, 440.5);
      expect(status(tester), 'In tune!');
      await tester.pump(const Duration(seconds: 2)); // sparkles
      await tester.tap(find.byKey(const ValueKey('tuner_stop')));
      await tester.pump();
      expect(find.byKey(const ValueKey('tuner_ready')), findsOneWidget);
      expect(fake.ctl, isNull, reason: 'the microphone stopped');
    });

    testWidgets('A = 442 lives in the settings sheet, is saved and retargets', (tester) async {
      final fake = await pumpTuner(tester);
      expect(find.text('A = 442'), findsNothing);
      await listen(tester);
      await openSettings(tester);
      await tester.tap(find.text('A = 442'));
      await tester.pump();
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
      final fake = await pumpTuner(tester, mandolin: true);
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
      expect(find.text('−45.0¢'), findsOneWidget);
    });

    testWidgets('microphone refused, then back to playing', (tester) async {
      await pumpTuner(tester, deny: true);
      await listen(tester);
      expect(find.byKey(const ValueKey('tuner_mic_denied')), findsOneWidget);
      await tester.tap(find.text('Back to playing'));
      await tester.pump();
      expect(find.byKey(const ValueKey('tuner_ready')), findsOneWidget);
    });
  });
}

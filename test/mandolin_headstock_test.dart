import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pitch_tuner/pitch_tuner.dart';
import 'package:violin_practice_companion/services/tuner_advice.dart';
import 'package:violin_practice_companion/ui/stringlings/mandolin_headstock.dart';

void main() {
  final mandolin = InstrumentTuning.mandolin();
  TunerReading at(String course, double cents, {TunerTrend trend = TunerTrend.none}) {
    final s = mandolin.strings.firstWhere((s) => s.name[0] == course);
    return TunerReading(s, cents, s.hz, live: true, inTune: false, trend: trend);
  }

  String say(TunerReading r) => tunerStatus(r, listening: true, playing: false, fineTuners: false);

  // Checked by hand on a right-handed mandolin: seen end-on, clockwise
  // loosens every tuner, so the tops roll opposite ways on the two sides.
  test('to tighten, G and D roll toward the end, A and E toward the body', () {
    expect(say(at('G', -10)), 'Flat · roll top toward the headstock end');
    expect(say(at('D', -10)), 'Flat · roll top toward the headstock end');
    expect(say(at('A', -10)), 'Flat · roll top toward the body');
    expect(say(at('E', -10)), 'Flat · roll top toward the body');
    expect(say(at('G', 10)), 'Sharp · roll top toward the body');
    expect(say(at('E', 10)), 'Sharp · roll top toward the headstock end');
  });

  test('a mandolin has no pegs: a long way out is the same roll', () {
    expect(say(at('A', -45)), 'Very flat · roll top toward the body');
    expect(say(at('D', 45)), 'Very sharp · roll top toward the body');
  });

  test('trends say the way to roll', () {
    expect(say(at('E', 12, trend: TunerTrend.wrongWay)), 'Wrong way! Roll top toward the headstock end');
    expect(say(at('G', 12, trend: TunerTrend.overshot)), 'Too far! Roll back toward the body');
    expect(say(at('D', -12, trend: TunerTrend.closer)), 'Closer! Keep rolling toward the headstock end');
  });

  test('a violin close to the note gets half a turn only; further out, a turn', () {
    final violin = InstrumentTuning.violin();
    final a = violin.strings.firstWhere((s) => s.name[0] == 'A');
    String v(double c, [TunerTrend trend = TunerTrend.none]) => tunerStatus(
        TunerReading(a, c, a.hz, live: true, inTune: false, trend: trend),
        listening: true, playing: false, fineTuners: true);
    expect(v(-25), 'Flat · turn the fine tuner clockwise');
    expect(v(-12), 'Flat · half a turn clockwise, no more');
    expect(v(8), 'Sharp · half a turn anti-clockwise, no more');
    expect(v(8, TunerTrend.overshot), 'Too far! Half a turn back, anti-clockwise');
    expect(v(-8, TunerTrend.wrongWay), 'Wrong way! Half a turn clockwise');
    expect(v(-30, TunerTrend.wrongWay), 'Wrong way! Turn clockwise instead');
  });

  testWidgets('draws every course, both hands, both views, twisting or still', (tester) async {
    for (final buttonOnly in [false, true]) {
      for (final left in [false, true]) {
        for (final course in ['G', 'D', 'A', 'E', null]) {
          for (final tighten in [true, false, null]) {
            await tester.pumpWidget(MaterialApp(
              home: Center(
                child: SizedBox(
                  width: 340,
                  height: 130,
                  child: MandolinHeadstock(
                      course: course, tighten: tighten, leftHanded: left, buttonOnly: buttonOnly && course != null),
                ),
              ),
            ));
            await tester.pump(const Duration(milliseconds: 700));
            expect(tester.takeException(), isNull);
          }
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}

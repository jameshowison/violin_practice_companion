import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:string_tuner/string_tuner.dart';
import 'package:violin_practice_companion/services/tuner_advice.dart';
import 'package:violin_practice_companion/services/tuner_model.dart';
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
    expect(say(at('G', -10)), 'Flat · roll the top toward the headstock end');
    expect(say(at('D', -10)), 'Flat · roll the top toward the headstock end');
    expect(say(at('A', -10)), 'Flat · roll the top toward the body');
    expect(say(at('E', -10)), 'Flat · roll the top toward the body');
    expect(say(at('G', 10)), 'Sharp · roll the top toward the body');
    expect(say(at('E', 10)), 'Sharp · roll the top toward the headstock end');
  });

  test('a mandolin has no pegs: a long way out is the same roll', () {
    expect(say(at('A', -45)), 'Very flat · roll the top toward the body');
    expect(say(at('D', 45)), 'Very sharp · roll the top toward the body');
  });

  test('trends say the way to roll', () {
    expect(say(at('E', 12, trend: TunerTrend.wrongWay)), 'Wrong way! Roll the top toward the headstock end');
    expect(say(at('G', 12, trend: TunerTrend.overshot)), 'Too far! Roll it back a little, toward the body');
    expect(say(at('D', -12, trend: TunerTrend.closer)), 'Closer! Keep rolling toward the headstock end');
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

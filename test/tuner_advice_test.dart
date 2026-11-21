import 'package:flutter_test/flutter_test.dart';
import 'package:pitch_tuner/pitch_tuner.dart';
import 'package:violin_practice_companion/services/tuner_advice.dart';

// The tuner's words, on readings made up for them. What the model reads
// from the microphone is tested in packages/pitch_tuner.
void main() {
  test('one in tune may be luck: the celebration waits for a run', () {
    final a = InstrumentTuning.mandolin().strings.firstWhere((s) => s.name == 'A4');
    TunerReading run(int n) => TunerReading(a, 0.5, a.hz, live: true, inTune: true, inTuneRun: n);
    String say(int n) => tunerStatus(run(n), listening: true, playing: false, fineTuners: false);
    expect(say(1), 'In tune! Play it again to check');
    expect(say(2), 'In tune! Once more');
    expect(say(TunerModel.celebrateAfter), 'In tune!');
  });

  test('the words for a pair of strings', () {
    final mandolin = InstrumentTuning.mandolin();
    final a = mandolin.strings.firstWhere((s) => s.name == 'A4');
    TunerReading at(double c, {bool inTune = false}) => TunerReading(a, c, a.hz, live: true, inTune: inTune);
    const beat = UnisonVerdict(beatHz: 1.3, cents: 5.1, strength: 2);
    const one = UnisonVerdict(beatHz: 0.3, cents: 1.2, strength: 2);
    expect(unisonStatus(beat, at(1, inTune: true)), 'They beat, 5¢ apart · tap to tune each');
    expect(unisonPassed(beat, at(1, inTune: true)), isFalse);
    expect(unisonStatus(one, at(-9)), 'Together, but both flat · tap to tune each');
    expect(unisonPassed(one, at(-9)), isFalse);
    expect(unisonStatus(one, at(1, inTune: true)), 'Together! Both strings in tune');
    expect(unisonPassed(one, at(-4.5)), isTrue, reason: 'within 5: each string was checked alone');
    expect(unisonPassed(one, at(1, inTune: true)), isTrue);
    expect(unisonStatus(null, null), 'Let both strings ring a little longer');
  });
}

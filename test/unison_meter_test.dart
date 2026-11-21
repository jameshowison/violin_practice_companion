import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pitch_tuner/pitch_tuner.dart';
import 'package:violin_practice_companion/services/tuner_advice.dart';
import 'package:violin_practice_companion/services/tuner_model.dart';
import 'package:violin_practice_companion/services/unison_meter.dart';

import 'support/plucked_pair.dart';

const rate = pluckRate;

/// Through the tracker (probing [hz]) and the meter, as the screen does.
UnisonVerdict? judge(Float32List audio, double hz) {
  final tracker = PitchTracker(YinDetector(sampleRate: rate.toDouble(), minHz: 150, maxHz: 1400))
    ..probeHz = hz;
  final meter = UnisonMeter();
  var plucked = false;
  for (final r in tracker.addSamples(audio)) {
    final at = Duration(microseconds: (r.endSample * 1e6 / rate).round());
    // The tuner's onset: the first frame with the note in it.
    final onset = !plucked && at > const Duration(milliseconds: 100);
    plucked |= onset;
    if (meter.add(at, r.bands!, courseHz: hz, onset: onset) == UnisonEvent.judged) return meter.verdict;
  }
  fail('never judged');
}

void main() {
  test('a probe reads a sine at its rms', () {
    final sine = Float32List.fromList(
        [for (var i = 0; i < 4096; i++) 0.5 * math.sin(2 * math.pi * 440 * i / rate)]);
    final r = (PitchTracker(YinDetector(sampleRate: rate.toDouble(), minHz: 150, maxHz: 1400))
          ..probeHz = 440)
        .addSamples(sine)
        .last;
    expect(r.bands![0], closeTo(0.5 / math.sqrt2, 0.01));
    expect(r.bands![1], lessThan(0.01), reason: 'no second harmonic in a sine');
  });

  test('a matched pair is together', () {
    final v = judge(pluck(293.66, 0), 293.66)!;
    expect(v.together, isTrue, reason: '$v');
  });

  test('one string alone is together (nothing to beat with)', () {
    final v = judge(pluck(440, 12, second: 0), 440)!;
    expect(v.together, isTrue, reason: '$v');
  });

  test('a pair a little apart beats, and the meter hears how far', () {
    for (final (hz, cents) in [(293.66, 10.0), (440.0, 5.0), (196.0, 25.0), (659.26, 6.0)]) {
      final v = judge(pluck(hz, cents), hz)!;
      expect(v.together, isFalse, reason: '$hz Hz, $cents¢: $v');
      expect(v.cents, closeTo(cents, 1.0), reason: '$hz Hz, $cents¢: $v');
    }
  });

  test('a beat too slow to hear in one pluck counts as together', () {
    final v = judge(pluck(440, 1.5), 440)!;
    expect(v.together, isTrue, reason: '$v');
  });

  test('the words', () {
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

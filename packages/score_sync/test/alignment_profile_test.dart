import 'dart:math' as math;
import 'dart:typed_data';

import 'package:score_sync/score_sync.dart';
import 'package:test/test.dart';

class _Note implements TimedNote {
  @override
  final double onsetSeconds, offsetSeconds;
  @override
  final int midiNote;
  const _Note(this.onsetSeconds, this.offsetSeconds, this.midiNote);
}

class _Score implements TimedScore {
  @override
  final List<TimedNote> notes;
  @override
  final List<double> measureOnsetSeconds;
  @override
  final List<int> measureNumbers;
  @override
  final double totalDurationSeconds;
  const _Score(this.notes, this.measureOnsetSeconds, this.measureNumbers,
      this.totalDurationSeconds);
}

/// Eight 2/4 bars, each a quarter note and a quarter rest, low on a violin
/// (G3 to D4): the rests are what ring, the low notes what the band floor
/// can lose.
const _pitches = [55, 57, 59, 60, 62, 60, 59, 57];

TimedScore _timing(List<int> pitches, int bpm) {
  final beat = 60.0 / bpm;
  return _Score(
    [
      for (var i = 0; i < pitches.length; i++)
        _Note(i * 2 * beat, (i * 2 + 1) * beat, pitches[i]),
    ],
    [for (var i = 0; i < pitches.length; i++) i * 2 * beat],
    [for (var i = 0; i < pitches.length; i++) i + 1],
    pitches.length * 2 * beat,
  );
}

/// The score at 90 bpm after a second of silence, each note a decaying
/// harmonic tone that rings on into its rest, as a string does.
Float64List _render(List<int> pitches, {int rate = 22050}) {
  const lead = 1.0, beat = 60.0 / 90;
  final total = lead + pitches.length * 2 * beat + 1;
  final out = Float64List((total * rate).round());
  for (var i = 0; i < pitches.length; i++) {
    final f0 = 440.0 * math.pow(2, (pitches[i] - 69) / 12.0);
    final start = ((lead + i * 2 * beat) * rate).round();
    final end = start + (2 * beat * rate).round();
    for (var s = start; s < end && s < out.length; s++) {
      final t = (s - start) / rate;
      final env = math.exp(-2.0 * t) * (1 - math.exp(-t * 400));
      var v = 0.0;
      for (var h = 1; h <= 5; h++) {
        v += math.sin(2 * math.pi * f0 * h * s / rate) / h;
      }
      out[s] += 0.3 * env * v;
    }
  }
  return out;
}

AutoAlignmentResult _align(AlignmentProfile? profile) {
  final aligner = profile == null
      ? ScoreAligner<List<int>>(timing: _timing)
      : ScoreAligner<List<int>>(timing: _timing, profile: profile);
  return aligner.alignSamples(_pitches, _render(_pitches), 22050);
}

void main() {
  test('the default profile is the parts\' own defaults, exactly', () {
    const p = AlignmentProfile.bowedStrings;
    expect(p.minFrequencyHz, 180);
    expect(p.maxFrequencyHz, 2600);
    expect(p.ringSeconds, 1.0);
    expect(p.onsetWeight, 0.3);
    expect(p, const AlignmentProfile());

    const extractor = AudioChromaExtractor();
    expect(p.minFrequencyHz, extractor.minFrequencyHz);
    expect(p.maxFrequencyHz, extractor.maxFrequencyHz);
    expect(p.ringSeconds, ScoreChromaReferenceBuilder().ringSeconds);
    expect(p.onsetWeight, const DtwAligner().onsetWeight);
  });

  test('copyWith changes one value and keeps equality honest', () {
    const p = AlignmentProfile.bowedStrings;
    final viola = p.copyWith(minFrequencyHz: 120);
    expect(viola.minFrequencyHz, 120);
    expect(viola.maxFrequencyHz, p.maxFrequencyHz);
    expect(viola, isNot(p));
    expect(viola, p.copyWith(minFrequencyHz: 120));
    expect(viola.hashCode, p.copyWith(minFrequencyHz: 120).hashCode);
  });

  test('ScoreAligner defaults to bowedStrings, bit for bit', () {
    expect(ScoreAligner<List<int>>(timing: _timing).profile,
        AlignmentProfile.bowedStrings);
    final none = _align(null);
    final given = _align(AlignmentProfile.bowedStrings);
    expect(given.averageDtwCost, none.averageDtwCost);
    expect([for (final a in given.anchors) a.audioSec],
        [for (final a in none.anchors) a.audioSec]);
  });

  group('each value reaches its stage', () {
    test('the band reaches the extractor', () {
      // 220 Hz then 330 Hz. The default band hears the A; a floor of 300 Hz
      // leaves the first half with nothing in band.
      const rate = 22050;
      final samples = Float64List(rate * 2);
      for (var i = 0; i < rate; i++) {
        samples[i] = 0.8 * math.sin(2 * math.pi * 220 * i / rate);
        samples[rate + i] = 0.8 * math.sin(2 * math.pi * 330 * i / rate);
      }
      final wide = AlignmentProfile.bowedStrings
          .extractor()
          .extractFromSamples(samples, rate.toDouble());
      final narrow = AlignmentProfile.bowedStrings
          .copyWith(minFrequencyHz: 300)
          .extractor()
          .extractFromSamples(samples, rate.toDouble());
      final q = wide.frames.length ~/ 4;
      expect(wide.frames[q][9], greaterThan(0.9));
      expect(narrow.frames[q][9], lessThan(0.5));
    });

    test('ringSeconds reaches the reference', () {
      final score = _timing(_pitches, 60);
      final rung = AlignmentProfile.bowedStrings.referenceBuilder();
      final dead = AlignmentProfile.bowedStrings
          .copyWith(ringSeconds: 0)
          .referenceBuilder();
      // Halfway through the first rest: G rings on, or is silent.
      final f = (1.5 / 0.05).round();
      expect(rung.build(score, 0.05).frames[f][7], greaterThan(0.9));
      expect(dead.build(score, 0.05).frames[f].every((x) => x == 0), isTrue);
    });

    test('onsetWeight reaches the DTW', () {
      expect(AlignmentProfile.bowedStrings.copyWith(onsetWeight: 0).dtw()
          .onsetWeight, 0);
    });

    // Through the aligner: changing any one value changes the alignment's
    // cost, so each is threaded through and none is dropped on the way.
    late final base = _align(AlignmentProfile.bowedStrings).averageDtwCost;
    for (final (name, p) in [
      ('band', AlignmentProfile.bowedStrings.copyWith(minFrequencyHz: 500)),
      ('ring', AlignmentProfile.bowedStrings.copyWith(ringSeconds: 0)),
      ('onset', AlignmentProfile.bowedStrings.copyWith(onsetWeight: 0)),
    ]) {
      test('ScoreAligner threads the $name', () {
        expect(_align(p).averageDtwCost, isNot(base));
      });
    }
  });
}

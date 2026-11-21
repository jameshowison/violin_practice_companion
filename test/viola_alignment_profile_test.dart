// The viola's alignment band (InstrumentProfile.viola.alignment) on a
// synthetic tune that lives on its C string, below the violin's 180 Hz floor.
//
// Self-contained like synthetic_alignment_robustness_test: the recording is
// rendered from the score, so the truth is exact, and no asset is needed. The
// score is a plain TimedScore rather than a ParsedPiece, since only the
// pitches and their times matter here.
//
// Measured when written: equal at 80 bpm (mean 0.062 s both), slightly
// better with the viola band at 120 (0.054 s against 0.059 s). The gap is
// small because a note's octave partial is the same pitch class, so the
// violin band still hears C3 through C4. This guards against the wider band
// making things worse; a real viola recording would show what it gains.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_sync/score_sync.dart';
import 'package:violin_practice_companion/models/instrument_profile.dart';

const _rate = 22050;

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

/// Sixteen 4/4 bars of quarters, almost all on the C string: C3 D3 E3 F3
/// (130.8-174.6 Hz), every fundamental below 180 Hz, with an open G3 now and
/// then.
const _bars = [
  [48, 50, 52, 48], [52, 53, 55, 55], [53, 52, 50, 48], [50, 50, 48, 48],
  [48, 48, 50, 52], [53, 52, 50, 50], [52, 52, 48, 48], [55, 53, 52, 50],
  [48, 52, 50, 53], [52, 55, 53, 50], [48, 50, 48, 50], [52, 53, 52, 53],
  [55, 52, 48, 52], [50, 53, 50, 48], [53, 55, 53, 52], [50, 48, 50, 48],
];

TimedScore _timing(List<List<int>> bars, int bpm) {
  final beat = 60.0 / bpm;
  final notes = <TimedNote>[];
  for (var b = 0; b < bars.length; b++) {
    for (var q = 0; q < 4; q++) {
      final t = (b * 4 + q) * beat;
      notes.add(_Note(t, t + beat, bars[b][q]));
    }
  }
  return _Score(
    notes,
    [for (var b = 0; b < bars.length; b++) b * 4 * beat],
    [for (var b = 0; b < bars.length; b++) b + 1],
    bars.length * 4 * beat,
  );
}

/// The tune at [bpm] after [lead] seconds of quiet, each note jittered and a
/// decaying tone whose fundamental dominates its partials, with a little
/// noise. Returns the samples and each bar's true start.
(Float64List, List<double>) _render(int bpm, {double lead = 2.0}) {
  final data = _timing(_bars, bpm);
  final total = lead + data.totalDurationSeconds + 2;
  final out = Float64List((total * _rate).round());
  final rnd = math.Random(5);
  final starts = <double>[];
  for (var i = 0; i < data.notes.length; i++) {
    final n = data.notes[i];
    final jitter = (rnd.nextDouble() - 0.5) * 0.08;
    final on = lead + n.onsetSeconds + jitter;
    if (i % 4 == 0) starts.add(on);
    final f0 = 440.0 * math.pow(2, (n.midiNote - 69) / 12.0);
    final s0 = (on * _rate).round();
    final s1 = ((lead + n.offsetSeconds + jitter) * _rate).round();
    for (var s = s0; s < s1 && s < out.length; s++) {
      final t = (s - s0) / _rate;
      final env = math.exp(-1.5 * t) * (1 - math.exp(-t * 400));
      var v = 0.0;
      for (var h = 1; h <= 4; h++) {
        v += math.sin(2 * math.pi * f0 * h * s / _rate) / (h * h);
      }
      out[s] += 0.3 * env * v;
    }
  }
  for (var s = 0; s < out.length; s++) {
    out[s] += 0.002 * (rnd.nextDouble() * 2 - 1);
  }
  return (out, starts);
}

/// Mean and worst absolute error of the bar anchors, in seconds.
(double, double) _error(AlignmentProfile profile, Float64List audio,
    List<double> truth) {
  final r = ScoreAligner<List<List<int>>>(timing: _timing, profile: profile)
      .alignSamples(_bars, audio, _rate.toDouble());
  // One anchor per bar here: no rests, so the pause pass adds none.
  final n = math.min(r.anchors.length, truth.length);
  var sum = 0.0, worst = 0.0;
  for (var i = 0; i < n; i++) {
    final e = (r.anchors[i].audioSec - truth[i]).abs();
    sum += e;
    worst = math.max(worst, e);
  }
  return (n == 0 ? 99.0 : sum / n, n == 0 ? 99.0 : worst);
}

void main() {
  test('the viola reads its C string: band floor below C3', () {
    final viola = InstrumentProfile.viola.alignment;
    final c3 = 440.0 * math.pow(2, (48 - 69) / 12.0);
    expect(viola.minFrequencyHz, lessThan(c3 * 0.95));
    // Nothing else differs from the violin's.
    expect(viola.copyWith(minFrequencyHz: 180), AlignmentProfile.bowedStrings);
  });

  test('violin and mandolin align with the violin defaults, exactly', () {
    expect(InstrumentProfile.violin.alignment, AlignmentProfile.bowedStrings);
    expect(InstrumentProfile.mandolin.alignment, AlignmentProfile.bowedStrings);
    expect(
        InstrumentProfile.viola
            .withTranscription(Transcription.fifthDown)
            .alignment,
        InstrumentProfile.viola.alignment);
  });

  test('a C-string tune aligns at least as well with the viola band', () {
    for (final bpm in [80, 120]) {
      final (audio, truth) = _render(bpm);
      final (violinMean, violinWorst) =
          _error(AlignmentProfile.bowedStrings, audio, truth);
      final (violaMean, violaWorst) =
          _error(InstrumentProfile.viola.alignment, audio, truth);
      // ignore: avoid_print
      print('$bpm bpm: violin band mean ${violinMean.toStringAsFixed(3)}s '
          'worst ${violinWorst.toStringAsFixed(3)}s; viola band mean '
          '${violaMean.toStringAsFixed(3)}s worst '
          '${violaWorst.toStringAsFixed(3)}s');
      expect(violaMean, lessThanOrEqualTo(violinMean + 0.01));
      expect(violaWorst, lessThan(0.25));
    }
  });
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:wav/wav.dart';

NoteEvent _note(int midi, NoteValue v) => NoteEvent(
      pitch: 'X',
      midiNumber: midi,
      octave: 4,
      noteValue: v,
      dotted: false,
      isRest: false,
    );

Uint8List _toneWavBytes(List<(double, double)> toneAndDurationSeconds,
    {int sampleRate = 44100}) {
  final chunks = <double>[];
  for (final (freq, dur) in toneAndDurationSeconds) {
    final n = (dur * sampleRate).round();
    for (var i = 0; i < n; i++) {
      chunks.add(0.8 * math.sin(2 * math.pi * freq * i / sampleRate));
    }
  }
  return Wav([Float64List.fromList(chunks)], sampleRate).write();
}

void main() {
  test(
      'a two-measure piece aligns to a real recording at a different '
      '(but proportionally matching) tempo', () {
    // Score: C4 half note, then E4 half note, at a nominal 60 BPM (2s each,
    // 4s total). The "real recording" instead plays each pitch for 3s
    // (6s total) — a slower, but still constant, tempo. The aligner's
    // duration-based tempo estimate should recover ~40 BPM (3s half notes),
    // and the resulting anchors should land close to the true 0s / 3s
    // measure onsets in the real recording.
    final piece = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      measures: [
        Measure(number: 1, notes: [_note(60, NoteValue.half)]), // C4, pc 0
        Measure(number: 2, notes: [_note(64, NoteValue.half)]), // E4, pc 4
      ],
    );
    final wavBytes = _toneWavBytes([(261.63, 3.0), (329.63, 3.0)]);

    final aligner = AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest());
    final result = aligner.align(piece, wavBytes);

    expect(result.anchors, hasLength(2));
    expect(result.generationBpm, closeTo(40, 2));
    expect(result.anchors[0].audioSec, closeTo(0.0, 0.15));
    expect(result.anchors[1].audioSec, closeTo(3.0, 0.2));
    // A near-exact tempo match should align almost perfectly frame-for-frame.
    expect(result.averageDtwCost, lessThan(0.05));
  });

  test('anchors are monotonically increasing in audioSec across many measures',
      () {
    // Four measures, alternating pitch, each a quarter note at 60 BPM (1s),
    // played back in the "recording" at a brisker, still-constant tempo.
    final piece = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      measures: List.generate(
        4,
        (i) => Measure(
            number: i + 1,
            notes: [_note(i.isEven ? 60 : 67, NoteValue.quarter)]), // C or G
      ),
    );
    final wavBytes = _toneWavBytes([
      (261.63, 0.6),
      (392.00, 0.6),
      (261.63, 0.6),
      (392.00, 0.6),
    ]);

    final aligner = AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest());
    final result = aligner.align(piece, wavBytes);

    expect(result.anchors, hasLength(4));
    for (var i = 1; i < result.anchors.length; i++) {
      expect(result.anchors[i].audioSec,
          greaterThanOrEqualTo(result.anchors[i - 1].audioSec));
      expect(result.anchors[i].scoreMs,
          greaterThan(result.anchors[i - 1].scoreMs));
    }
  });

  group('smoothAnchors', () {
    // Regression fixture for docs/audio-sync-dtw-anchor-compression.md:
    // Salt Creek's real alignment paced at a uniform ~1256.5ms/measure in
    // scoreMs, but at measures 18-19 (and again at 27-28) two consecutive
    // audioSec deltas collapsed to roughly half the surrounding pace because
    // the DTW cost matrix had little to discriminate on across those
    // chroma-ambiguous measures. Reproduce that exact shape at 1/1000th scale
    // (scoreMs still 1256.5, audioSec deltas taken straight from the doc).
    List<ScoreAudioAnchor> saltCreekLikeAnchors() {
      const normalDeltas = [
        2.624, 0.952, 1.207, 1.161, 1.324, 1.068, 1.231, 1.184, // 1-8
        1.207, 1.231, 1.184, 1.161, 1.347, 1.068, 1.231, 1.161, // 9-16
        1.207, // 17
      ];
      const compressedRun1 = [0.557, 0.697]; // 18, 19 <<< compressed
      const middleDeltas = [
        1.161, 1.207, 1.184, 1.184, 1.231, 1.184, 1.138, // 20-26
      ];
      const compressedRun2 = [0.580, 0.697]; // 27, 28 <<< compressed
      const tailDeltas = [1.184, 1.207, 1.207, 1.184, 1.207, 1.184]; // 29-34
      final deltas = [
        ...normalDeltas,
        ...compressedRun1,
        ...middleDeltas,
        ...compressedRun2,
        ...tailDeltas,
      ];

      var scoreMs = 314.1, audioSec = 0.0;
      final anchors = [ScoreAudioAnchor(0, 0)];
      for (final delta in deltas) {
        audioSec += delta;
        anchors.add(ScoreAudioAnchor(scoreMs, audioSec));
        scoreMs += 1256.5;
      }
      return anchors;
    }

    test('drops the anchor squeezed by a run of two compressed segments', () {
      final anchors = saltCreekLikeAnchors();

      final smoothed = AudioScoreAutoAligner.smoothAnchors(anchors);

      // Anchors 18 and 27 (1-based, i.e. list indices 18 and 27 once the
      // leading pickup anchor at index 0 is counted) sit strictly between two
      // compressed segments and should be discarded; every other anchor
      // (including the other endpoint of each compressed run) survives.
      expect(smoothed, hasLength(anchors.length - 2));
      final survivingScoreMs = smoothed.map((a) => a.scoreMs).toSet();
      expect(survivingScoreMs.contains(anchors[18].scoreMs), isFalse);
      expect(survivingScoreMs.contains(anchors[27].scoreMs), isFalse);
      for (var i = 0; i < anchors.length; i++) {
        if (i == 18 || i == 27) continue;
        expect(survivingScoreMs.contains(anchors[i].scoreMs), isTrue,
            reason: 'anchor $i should have survived smoothing');
      }

      // The surviving anchors interpolate across the removed gap in one
      // smooth segment instead of stair-stepping through the bad points.
      for (var i = 1; i < smoothed.length; i++) {
        expect(smoothed[i].audioSec,
            greaterThan(smoothed[i - 1].audioSec));
        expect(smoothed[i].scoreMs, greaterThan(smoothed[i - 1].scoreMs));
      }
    });

    test('leaves a normal, uncompressed anchor sequence untouched', () {
      final anchors = [
        for (var i = 0; i < 10; i++) ScoreAudioAnchor(i * 1256.5, i * 1.2)
      ];

      final smoothed = AudioScoreAutoAligner.smoothAnchors(anchors);

      expect(smoothed, equals(anchors));
    });

    test('leaves an isolated single compressed segment alone', () {
      // Only one bad segment (18) with normal pace on both sides — no run of
      // 2+, so there's no way to tell which endpoint is at fault.
      var scoreMs = 0.0, audioSec = 0.0;
      final anchors = [ScoreAudioAnchor(scoreMs, audioSec)];
      const deltas = [1.2, 1.2, 1.2, 1.2, 0.5, 1.2, 1.2, 1.2, 1.2];
      for (final delta in deltas) {
        scoreMs += 1256.5;
        audioSec += delta;
        anchors.add(ScoreAudioAnchor(scoreMs, audioSec));
      }

      final smoothed = AudioScoreAutoAligner.smoothAnchors(anchors);

      expect(smoothed, equals(anchors));
    });

    test('returns anchors unchanged when there are too few to smooth', () {
      const anchors = [
        ScoreAudioAnchor(0, 0),
        ScoreAudioAnchor(1256.5, 0.1),
        ScoreAudioAnchor(2513.0, 2.0),
      ];

      expect(AudioScoreAutoAligner.smoothAnchors(anchors), equals(anchors));
    });
  });
}

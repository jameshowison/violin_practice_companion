import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/dtw_align.dart';
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

  test(
      'a recording with a leading intro the score does not have still '
      'anchors the first measure near the intro\'s real end, not near 0',
      () {
    // Same two-measure piece/tempo as the first test above, but the "real
    // recording" now opens with a 2.5s burst of F#4 (pitch class 6) before
    // the performance starts — a pitch class neither C4 (pc 0) nor E4 (pc 4)
    // shares, standing in for a spoken/instrumental intro the score has no
    // counterpart for. Before open-begin DTW, the forced (0,0) start would
    // have smeared this whole intro into a false match against the first
    // measure, anchoring it near audioSec 0 instead of ~2.5s.
    final piece = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      measures: [
        Measure(number: 1, notes: [_note(60, NoteValue.half)]), // C4, pc 0
        Measure(number: 2, notes: [_note(64, NoteValue.half)]), // E4, pc 4
      ],
    );
    final wavBytes = _toneWavBytes([
      (369.99, 2.5), // F#4 "intro", pc 6 — no overlap with the score's notes
      (261.63, 3.0), // C4
      (329.63, 3.0), // E4
    ]);

    final aligner = AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest());
    final result = aligner.align(piece, wavBytes);

    expect(result.anchors, hasLength(2));
    expect(result.anchors[0].audioSec, closeTo(2.5, 0.3));
    expect(result.anchors[1].audioSec, closeTo(5.5, 0.3));
    expect(
        result.anchors[1].audioSec, greaterThan(result.anchors[0].audioSec));
  });

  group('content window', () {
    // The score for every test here: C4 half note, then E4 half note.
    final piece = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      measures: [
        Measure(number: 1, notes: [_note(60, NoteValue.half)]), // C4, pc 0
        Measure(number: 2, notes: [_note(64, NoteValue.half)]), // E4, pc 4
      ],
    );
    const c4 = 261.63, e4 = 329.63, fSharp4 = 369.99;

    AutoAlignmentResult align(Uint8List wav,
            {double? contentStartSeconds,
            double? contentEndSeconds,
            double? skipPenaltyPerFrame}) =>
        AudioScoreAutoAligner(
          midiGenerator: MidiGenerator.forTest(),
          dtw: skipPenaltyPerFrame == null
              ? null
              : DtwAligner(skipPenaltyPerFrame: skipPenaltyPerFrame),
        ).align(
          piece,
          wav,
          contentStartSeconds: contentStartSeconds,
          contentEndSeconds: contentEndSeconds,
        );

    test('a given start takes the skip penalty out of the decision', () {
      // The point of the whole feature. `skipPenaltyPerFrame` is the one
      // constant deciding, from audio alone, whether a lead-in is unmatched
      // content or the first notes of the piece, and its usable window rests
      // on two real recordings, one per edge (docs/audio-sync-next-steps.md).
      // Here the lead-in QUOTES the tune — the first 4s restate C4 then E4
      // before the performance proper — which is Lightly Row's real shape and
      // the edge inference handles worst.
      final wav = _toneWavBytes([
        (c4, 2.0), // ├ intro: the tune's own first phrase
        (e4, 2.0), // ┘
        (c4, 3.0), // the performance
        (e4, 3.0),
      ]);

      // Inferred, the answer moves with the constant: raise it past the point
      // where skipping stops looking worthwhile and anchor 0 is dragged back
      // into the intro, which is the regression
      // test/lightly_row_intro_align_test.dart guards against on real audio.
      expect(align(wav).anchors.first.audioSec, closeTo(4.0, 0.3));
      expect(align(wav, skipPenaltyPerFrame: 0.4).anchors.first.audioSec,
          closeTo(0.0, 0.3));

      // Told, it does not move at all.
      for (final penalty in [0.05, 0.18, 0.4]) {
        final told = align(wav,
            contentStartSeconds: 4.0, skipPenaltyPerFrame: penalty);
        expect(told.anchors, hasLength(2));
        expect(told.anchors[0].audioSec, closeTo(4.0, 0.3),
            reason: 'at skip penalty $penalty');
        expect(told.anchors[1].audioSec, closeTo(7.0, 0.3),
            reason: 'at skip penalty $penalty');
      }
    });

    test('a given end discards a trailing repeat of the tune', () {
      // Galopede's recording loops back to the top after the tune ends; the
      // same shape, at 1/10th the length.
      final wav = _toneWavBytes([
        (c4, 3.0),
        (e4, 3.0),
        (c4, 3.0), // the loop-back, which resembles the score just as much
      ]);

      final told = align(wav, contentEndSeconds: 6.0);
      expect(told.anchors, hasLength(2));
      expect(told.anchors[0].audioSec, closeTo(0.0, 0.3));
      expect(told.anchors[1].audioSec, closeTo(3.0, 0.3));
    });

    test('the tempo estimate is taken from the window, not the whole file', () {
      // 6s of music followed by 10s that are not. The estimate divides the
      // piece's 4 quarter-note beats by the duration it is given, so counting
      // all 16s says 15 BPM (clamped to 20) where the tune really runs at 40.
      final wav = _toneWavBytes([(c4, 3.0), (e4, 3.0), (fSharp4, 10.0)]);

      expect(align(wav).generationBpm, lessThan(25));
      expect(align(wav, contentEndSeconds: 6.0).generationBpm, closeTo(40, 2));
    });

    test('anchors come back in real audio time, not window time', () {
      // The window is an implementation detail of the DTW run; everything
      // downstream (playback position, the video overlay's offset) speaks
      // seconds-into-the-file, so the window's own start has to go back on.
      final wav = _toneWavBytes([(fSharp4, 5.0), (c4, 3.0), (e4, 3.0)]);

      final told = align(wav, contentStartSeconds: 5.0);
      expect(told.anchors[0].audioSec, closeTo(5.0, 0.3));
      expect(told.anchors[1].audioSec, closeTo(8.0, 0.3));
    });

    test('an absent window aligns exactly as before', () {
      final wav = _toneWavBytes([(c4, 3.0), (e4, 3.0)]);
      final inferred = align(wav);
      final bothNull = align(wav,
          contentStartSeconds: null, contentEndSeconds: null);

      expect(bothNull.generationBpm, inferred.generationBpm);
      for (var i = 0; i < inferred.anchors.length; i++) {
        expect(bothNull.anchors[i].audioSec, inferred.anchors[i].audioSec);
      }
    });

    test('a window covering the whole file is the same as no window', () {
      // Bounds clamp to the recording rather than being rejected, so an end
      // taken from a longer file (or a start of 0) is harmless.
      final wav = _toneWavBytes([(c4, 3.0), (e4, 3.0)]);
      final inferred = align(wav);
      final clamped =
          align(wav, contentStartSeconds: 0.0, contentEndSeconds: 999.0);

      expect(clamped.generationBpm, inferred.generationBpm);
      for (var i = 0; i < inferred.anchors.length; i++) {
        expect(clamped.anchors[i].audioSec, inferred.anchors[i].audioSec);
      }
    });

    test('a window too short to hold a performance falls back to inference',
        () {
      // A figure typed against the wrong file, or a stray keystroke. Aligning
      // against a fraction of a second would produce confident nonsense; the
      // pre-window answer is the one that loses least.
      final wav = _toneWavBytes([(c4, 3.0), (e4, 3.0)]);
      final inferred = align(wav);

      for (final window in [
        (start: 5.6, end: 5.9), // narrower than minContentWindowSeconds
        (start: 90.0, end: null), // past the end of the recording
        (start: 4.0, end: 4.2),
      ]) {
        final result =
            align(wav, contentStartSeconds: window.start, contentEndSeconds: window.end);
        expect(result.generationBpm, inferred.generationBpm,
            reason: 'window $window should have been ignored');
        expect(result.anchors.first.audioSec, inferred.anchors.first.audioSec,
            reason: 'window $window should have been ignored');
      }
    });
  });

  group('hasCompressedRun', () {
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

    test('detects a run of two compressed segments', () {
      final anchors = saltCreekLikeAnchors();

      expect(AudioScoreAutoAligner.hasCompressedRun(anchors), isTrue);
    });

    test('leaves a normal, uncompressed anchor sequence undetected', () {
      final anchors = [
        for (var i = 0; i < 10; i++) ScoreAudioAnchor(i * 1256.5, i * 1.2)
      ];

      expect(AudioScoreAutoAligner.hasCompressedRun(anchors), isFalse);
    });

    test('does not flag an isolated single compressed segment', () {
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

      expect(AudioScoreAutoAligner.hasCompressedRun(anchors), isFalse);
    });

    test('returns false when there are too few anchors to evaluate', () {
      const anchors = [
        ScoreAudioAnchor(0, 0),
        ScoreAudioAnchor(1256.5, 0.1),
        ScoreAudioAnchor(2513.0, 2.0),
      ];

      expect(AudioScoreAutoAligner.hasCompressedRun(anchors), isFalse);
    });
  });
}

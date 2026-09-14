import 'dart:typed_data';

import '../models/parsed_piece.dart';
import 'audio_chroma_features.dart';
import 'dtw_align.dart';
import 'midi_generator.dart';
import 'score_chroma_reference.dart';

/// One (score-timeline-millisecond, real-audio-second) calibration point.
/// [scoreMs] is in the timeline generated at [AutoAlignmentResult.generationBpm]
/// — a caller must regenerate [MidiGenerator.generate] at that same BPM to
/// get a highlight-event timeline these anchors are consistent with.
class ScoreAudioAnchor {
  final double scoreMs;
  final double audioSec;

  const ScoreAudioAnchor(this.scoreMs, this.audioSec);
}

class AutoAlignmentResult {
  /// One anchor per performed measure, sorted by [ScoreAudioAnchor.audioSec].
  final List<ScoreAudioAnchor> anchors;

  /// The arbitrary tempo the reference timeline (and hence [anchors]'
  /// `scoreMs`) was generated at — must be reused by playback so its
  /// highlight-event timeline lines up with these anchors.
  final int generationBpm;

  /// Mean per-frame DTW cost (cosine distance) along the alignment path —
  /// see [DtwResult.averageCost]. No fixed pass/fail threshold; useful for
  /// logging/diagnostics, not as a hard gate.
  final double averageDtwCost;

  const AutoAlignmentResult(this.anchors, this.generationBpm, this.averageDtwCost);
}

/// Aligns a piece's score to a real recording of it, fully on-device: builds
/// a symbolic reference chroma curve directly from the score's own notes (no
/// audio synthesis), extracts real chroma from the recording, runs DTW
/// between them, and reads each measure's real-audio timestamp off the warp
/// path. Only measure-level granularity is needed — not per-note alignment.
class AudioScoreAutoAligner {
  final MidiGenerator _midiGenerator;
  final AudioChromaExtractor _extractor;
  final DtwAligner _dtw;

  AudioScoreAutoAligner({
    MidiGenerator? midiGenerator,
    AudioChromaExtractor? extractor,
    DtwAligner? dtw,
  })  : _midiGenerator = midiGenerator ?? MidiGenerator(),
        _extractor = extractor ?? const AudioChromaExtractor(),
        _dtw = dtw ?? const DtwAligner();

  /// [wavBytes] is a whole WAV file's bytes for the recording to align
  /// against [piece].
  AutoAlignmentResult align(ParsedPiece piece, Uint8List wavBytes) {
    final realChroma = _extractor.extractFromWavBytes(wavBytes);
    final realDurationSeconds = realChroma.durationSeconds;

    // Estimate a starting tempo so the reference's frame count is roughly
    // comparable to the real recording's, which keeps the DTW search band
    // meaningful. At 60 BPM one quarter note lasts exactly one second, so
    // totalDurationSeconds generated at 60 BPM IS the piece's total
    // quarter-note-beat count — scale that to fit the real duration.
    final quarterBeatCount =
        _midiGenerator.generate(piece, 60).totalDurationSeconds;
    final estimatedBpm =
        (60 * quarterBeatCount / realDurationSeconds).round().clamp(20, 400);

    final reference = ScoreChromaReferenceBuilder(_midiGenerator)
        .build(piece, estimatedBpm, realChroma.hopSeconds);

    final dtwResult = _dtw.align(reference.frames, realChroma.frames);

    final anchors = <ScoreAudioAnchor>[];
    for (var i = 0; i < reference.measureOnsetSeconds.length; i++) {
      final referenceFrame =
          (reference.measureOnsetSeconds[i] / reference.hopSeconds).round();
      final targetFrame = _targetFrameFor(dtwResult.path, referenceFrame);
      if (targetFrame == null) continue;
      anchors.add(ScoreAudioAnchor(
        reference.measureOnsetSeconds[i] * 1000,
        targetFrame * realChroma.hopSeconds,
      ));
    }

    return AutoAlignmentResult(
        smoothAnchors(anchors), estimatedBpm, dtwResult.averageCost);
  }

  /// Anchor count below which [smoothAnchors] won't attempt outlier removal —
  /// too few segments for a rolling-median comparison to mean anything.
  static const _minAnchorsForSmoothing = 6;

  /// Detects and drops anchors that the raw DTW path squeezed together
  /// locally rather than genuinely tracking the audio — see
  /// docs/audio-sync-dtw-anchor-compression.md. [anchors] must be in
  /// performance order (as built by [align], strictly increasing in
  /// [ScoreAudioAnchor.scoreMs]).
  ///
  /// When the score paces evenly but the DTW cost matrix has little to
  /// discriminate on for a couple of consecutive measures (e.g. a repeated
  /// melodic cell), the path can advance many reference frames while barely
  /// advancing through the target audio, so two or more consecutive segments'
  /// audio-per-score pace collapses to a fraction of the surrounding pace.
  /// The anchor(s) sandwiched between such a run of low-pace segments — the
  /// ones the path squeezed together — are dropped; [AudioSyncPlaybackService]'s
  /// existing piecewise-linear interpolation then spans the resulting
  /// (correctly-sized) gap directly between the surviving, trustworthy
  /// neighbors instead of stair-stepping through the bad points.
  ///
  /// An isolated single flagged segment (not part of a run of 2+) is left
  /// alone: with only one bad segment there's no way to tell which of its two
  /// endpoint anchors is at fault, so nothing is discarded.
  static List<ScoreAudioAnchor> smoothAnchors(
    List<ScoreAudioAnchor> anchors, {
    double outlierRatio = 0.6,
    int medianWindowRadius = 3,
  }) {
    final n = anchors.length;
    if (n < _minAnchorsForSmoothing) return anchors;

    // pace[i] (i in 1..n-1) is the local audio-seconds-per-score-millisecond
    // rate across segment (anchors[i-1], anchors[i]).
    final pace = List<double>.filled(n, double.nan);
    for (var i = 1; i < n; i++) {
      final scoreDelta = anchors[i].scoreMs - anchors[i - 1].scoreMs;
      final audioDelta = anchors[i].audioSec - anchors[i - 1].audioSec;
      if (scoreDelta > 0) pace[i] = audioDelta / scoreDelta;
    }

    final flagged = List<bool>.filled(n, false);
    for (var i = 1; i < n; i++) {
      if (pace[i].isNaN) continue;
      final neighbors = <double>[];
      for (var j = i - medianWindowRadius; j <= i + medianWindowRadius; j++) {
        if (j == i || j < 1 || j >= n || pace[j].isNaN) continue;
        neighbors.add(pace[j]);
      }
      if (neighbors.length < 2) continue;
      neighbors.sort();
      final median = neighbors[neighbors.length ~/ 2];
      if (median <= 0) continue;
      final ratio = pace[i] / median;
      if (ratio < outlierRatio || ratio > 1 / outlierRatio) {
        flagged[i] = true;
      }
    }

    final toDiscard = List<bool>.filled(n, false);
    var i = 1;
    while (i < n) {
      if (!flagged[i]) {
        i++;
        continue;
      }
      var runEnd = i;
      while (runEnd + 1 < n && flagged[runEnd + 1]) {
        runEnd++;
      }
      // Anchors strictly interior to the flagged run — touched by a flagged
      // segment on both sides — are the ones the path squeezed together.
      for (var a = i; a < runEnd; a++) {
        toDiscard[a] = true;
      }
      i = runEnd + 1;
    }

    if (!toDiscard.contains(true)) return anchors;
    return [
      for (var k = 0; k < n; k++)
        if (!toDiscard[k]) anchors[k]
    ];
  }

  /// [path] is sorted by reference-frame index (component `$1`); returns the
  /// target-frame index of the first entry at or after [frameIndex].
  int? _targetFrameFor(List<(int, int)> path, int frameIndex) {
    if (path.isEmpty) return null;
    var lo = 0, hi = path.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (path[mid].$1 < frameIndex) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return path[lo].$2;
  }
}

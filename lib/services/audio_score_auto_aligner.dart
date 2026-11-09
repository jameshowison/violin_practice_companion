import 'dart:math' as math;
import 'dart:typed_data';

import '../models/parsed_piece.dart';
import 'audio_chroma_features.dart';
import 'audio_decoder_base.dart' show PcmAudio;
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

  /// True if [anchors] shows the anchor-compression signature described in
  /// docs/audio-sync-dtw-anchor-compression.md — see
  /// [AudioScoreAutoAligner.hasCompressedRun]. The confirmed case of this
  /// (Salt Creek) turned out to be a genuinely wrong score, not a DTW quirk —
  /// a missing first/second-ending distinction had produced extra, duplicate
  /// measures — so this is surfaced to the user to review rather than
  /// silently "fixed" by discarding anchors.
  final bool hasCompressedAnchors;

  const AutoAlignmentResult(
    this.anchors,
    this.generationBpm,
    this.averageDtwCost, {
    this.hasCompressedAnchors = false,
  });
}

/// Suggested message for the UI to show when [AutoAlignmentResult.hasCompressedAnchors]
/// (or a cached alignment's stored equivalent) is true.
///
/// Deliberately names both causes and does not assert which. The wording used
/// to blame the score outright, on the strength of the one confirmed case
/// (Salt Creek's duplicate measures — see
/// docs/audio-sync-dtw-anchor-compression.md). That is no longer safe: with
/// that score corrected, the same recording still trips the flag while every
/// one of its 32 anchors lands within 100ms of a real note onset, so the
/// signal now has a known false-positive mode and shouldn't send anyone
/// hunting for a score bug that isn't there.
const String alignmentReviewMessage =
    'Some measures may be highlighted slightly early or late. If the score '
    "doesn't quite match what was played, check for an extra or missing "
    'measure, or a first/second ending (not currently supported: repeat both '
    'endings out as plain measures instead), then tap Realign. Otherwise the '
    'recording itself may be hard to follow — a quiet one, or one with a lot '
    'of background hum, gives the aligner less to work with. Playback is '
    'usable either way.';

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
  ///
  /// The WAV-shaped entry point, kept because every bundled analysis track and
  /// every in-app capture is a WAV, and because it is what the alignment
  /// regression tests drive. Anything the user brought with them arrives
  /// through [alignPcm] instead, already decoded.
  AutoAlignmentResult align(
    ParsedPiece piece,
    Uint8List wavBytes, {
    double? contentStartSeconds,
    double? contentEndSeconds,
  }) =>
      alignChroma(
        piece,
        _extractor.extractFromWavBytes(wavBytes),
        contentStartSeconds: contentStartSeconds,
        contentEndSeconds: contentEndSeconds,
      );

  /// Aligns against already-decoded mono PCM — an imported mp3/m4a/mp4 that
  /// [AudioDecoder] has read. Identical from here on: the extractor's two
  /// entry points converge on the same chroma sequence.
  AutoAlignmentResult alignPcm(
    ParsedPiece piece,
    PcmAudio audio, {
    double? contentStartSeconds,
    double? contentEndSeconds,
  }) =>
      alignChroma(
        piece,
        _extractor.extractFromSamples(audio.samples, audio.sampleRate),
        contentStartSeconds: contentStartSeconds,
        contentEndSeconds: contentEndSeconds,
      );

  /// Aligned with open begin/end boundaries (see [DtwAligner.align]) since
  /// real recordings commonly have a lead-in (spoken/instrumental intro,
  /// count-in) or trail-out the score has no counterpart for — forcing those
  /// onto the score's first/last notes is what produced visibly wrong
  /// early-measure anchors before this was open.
  ///
  /// [contentStartSeconds] and [contentEndSeconds] are the user's answer to
  /// "where in this recording is the tune", and both are optional: absent, this
  /// behaves exactly as it always has and the open boundaries work the span out
  /// from the audio alone. That inference is genuinely ambiguous — it is one
  /// constant, [DtwAligner.skipPenaltyPerFrame], deciding whether a lead-in is
  /// unmatched content or the first notes of the piece, and two real recordings
  /// pin opposite edges of its usable window (see
  /// docs/audio-sync-next-steps.md). Being told dissolves the ambiguity instead
  /// of tuning around it.
  ///
  /// The window is a HINT, not a hard edge. The boundaries stay open inside it,
  /// so a second or two of error in either figure is absorbed, and the end
  /// still has to discard things the score has no counterpart for (Galopede's
  /// recording loops back to the top of the tune after it finishes).
  ///
  /// It also fixes the tempo estimate below, which divides the piece's beat
  /// count by the recording's duration: counting seconds that are not the tune
  /// makes the estimate too slow (143 against a true ~168 on Galopede, whose
  /// 54s hold 46s of music).
  AutoAlignmentResult alignChroma(
    ParsedPiece piece,
    ChromaSequence realChroma, {
    double? contentStartSeconds,
    double? contentEndSeconds,
  }) {
    final window = _ContentWindow.of(
        realChroma, contentStartSeconds, contentEndSeconds);
    final realDurationSeconds = window.frames.length * realChroma.hopSeconds;

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

    final dtwResult = _dtw.align(reference.frames, window.frames,
        openBegin: true, openEnd: true);

    final anchors = <ScoreAudioAnchor>[];
    final referenceFrames = <int>[];
    for (var i = 0; i < reference.measureOnsetSeconds.length; i++) {
      final referenceFrame =
          (reference.measureOnsetSeconds[i] / reference.hopSeconds).round();
      final targetFrame = _targetFrameFor(dtwResult.path, referenceFrame);
      if (targetFrame == null) continue;
      referenceFrames.add(referenceFrame);
      anchors.add(ScoreAudioAnchor(
        reference.measureOnsetSeconds[i] * 1000,
        // DTW saw only the window, so its frame indices are relative to it —
        // the window's own start goes back on here, and anchors stay in real
        // audio time, which is the one timeline playback understands.
        (window.startFrame + targetFrame) * realChroma.hopSeconds,
      ));
    }

    final held = heldBarlines(
        _midiGenerator.generate(piece, estimatedBpm), anchors);
    final placed = refineAtNoteChanges(
      interpolateHeld(anchors, held),
      held,
      referenceFrames,
      reference.frames,
      window.frames,
      window.startFrame,
      realChroma.hopSeconds,
    );

    return AutoAlignmentResult(
      placed,
      estimatedBpm,
      dtwResult.averageCost,
      hasCompressedAnchors: hasCompressedRun(placed),
    );
  }

  /// Which of [anchors] fall on a barline that a note is HELD across — a tie
  /// into the bar, or any note sounding over it — with nothing struck there.
  ///
  /// Such a barline can't be seen in the recording. Chroma is the same on
  /// either side of it (the same pitch, still sounding), so every placement
  /// within the held note costs DTW the same and the path puts it wherever:
  /// on Gundagai, the bar held through by `G2-|G8-|G4` came out 0.16 s long
  /// against its neighbours' 1.4 s, with the time it lost added to the bars
  /// either side. Known from the score alone, before any audio is involved —
  /// which is the difference from [hasCompressedRun]'s after-the-fact
  /// guessing, and why this one can safely act rather than only flag.
  static List<bool> heldBarlines(
      MidiData midi, List<ScoreAudioAnchor> anchors) {
    const eps = 1e-6;
    return [
      for (final a in anchors)
        () {
          final t = a.scoreMs / 1000;
          final struck =
              midi.notes.any((n) => (n.onsetSeconds - t).abs() < eps);
          final sounding = midi.notes.any(
              (n) => n.onsetSeconds < t - eps && n.offsetSeconds > t + eps);
          return sounding && !struck;
        }(),
    ];
  }

  /// [anchors] with each [held] one moved onto the straight line between the
  /// nearest unheld anchors either side, by score time — the steady-tempo
  /// guess, which for a bar the recording gives no evidence about is the
  /// honest one. A held anchor with no unheld neighbour on one side (the very
  /// start or end of the tune) is left where DTW put it.
  static List<ScoreAudioAnchor> interpolateHeld(
      List<ScoreAudioAnchor> anchors, List<bool> held) {
    final out = [...anchors];
    for (var i = 0; i < anchors.length; i++) {
      if (!held[i]) continue;
      var lo = i - 1, hi = i + 1;
      while (lo >= 0 && held[lo]) {
        lo--;
      }
      while (hi < anchors.length && held[hi]) {
        hi++;
      }
      if (lo < 0 || hi >= anchors.length) continue;
      final a = anchors[lo], b = anchors[hi];
      final f = (anchors[i].scoreMs - a.scoreMs) / (b.scoreMs - a.scoreMs);
      out[i] = ScoreAudioAnchor(
          anchors[i].scoreMs, a.audioSec + f * (b.audioSec - a.audioSec));
    }
    return out;
  }

  /// How far (seconds of recording) [refineAtNoteChanges] will move an anchor.
  static const double refineWindowSeconds = 0.75;

  /// Frames of recording either side of a candidate barline that
  /// [refineAtNoteChanges] compares with the outgoing and incoming notes.
  static const int refineSideFrames = 5;

  /// Reference frames stepped back from / forward of the barline to read the
  /// outgoing and incoming notes. The reference builder gives a note frames
  /// `floor(onset)..ceil(offset)`, so the one or two frames at a note change
  /// hold both notes; three frames clears that blend.
  static const int _refineReferenceOffset = 3;

  /// [anchors] with each one at a struck note change moved to where the
  /// recording actually changes from the bar's outgoing note to its incoming
  /// one, within [refineWindowSeconds] of where DTW put it.
  ///
  /// DTW places a barline wherever the whole path is cheapest, which an
  /// accompaniment can pull a long way off. On Happy Farmer's violin + piano
  /// track the bar-1 downbeat arrives at 7.45 s with a piano chord heavy in
  /// the pickup's own D, so DTW held the pickup until the audio turned clearly
  /// G at 8.08 s, lighting the pickup for 1.4 s instead of 0.4 s. Snapping to
  /// the nearest attack doesn't help: the piano strikes every beat and the
  /// error was larger than a beat. What does locate it is the note change
  /// itself. Each candidate frame is scored by how well the frames just before
  /// it match the outgoing note plus how well the frames just after it match
  /// the incoming one, and the anchor goes to the best.
  ///
  /// That score alone is not enough. In a melody-only recording the same
  /// pair of notes can recur within the window, and on Gundagai it moved six
  /// good anchors by up to 0.7 s. So a candidate must also leave the bars
  /// either side at least as evenly paced as DTW's placement did. Happy
  /// Farmer's misplaced downbeat was obviously uneven (a 0.9-beat pickup that
  /// took 1.4 s against a 3.5-beat bar in 2.35 s), and the spurious Gundagai
  /// moves all made the tempo less even.
  ///
  /// Left where DTW put them: [held] anchors (no change to see), anchors whose
  /// outgoing or incoming reference frame is silent (a lead rest, the end),
  /// anchors whose two notes look alike in chroma (a repeated pitch), and the
  /// first and last anchors (no tempo on one side to judge by). Each anchor
  /// stays strictly between its neighbours, the previous one as already
  /// refined.
  static List<ScoreAudioAnchor> refineAtNoteChanges(
    List<ScoreAudioAnchor> anchors,
    List<bool> held,
    List<int> referenceFrames,
    List<Float64List> reference,
    List<Float64List> target,
    int targetStartFrame,
    double hopSeconds,
  ) {
    const side = refineSideFrames;
    const off = _refineReferenceOffset;
    final window = (refineWindowSeconds / hopSeconds).round();
    final out = [...anchors];
    int frameOf(ScoreAudioAnchor a) =>
        (a.audioSec / hopSeconds).round() - targetStartFrame;

    for (var i = 0; i < anchors.length; i++) {
      if (held[i]) continue;
      final r = referenceFrames[i];
      if (r - off < 0 || r + off >= reference.length) continue;
      final outgoing = reference[r - off], incoming = reference[r + off];
      if (_isSilent(outgoing) || _isSilent(incoming)) continue;
      if (_dot(outgoing, incoming) > 0.9) continue;

      // Both neighbours are needed to judge the tempo either side.
      if (i == 0 || i + 1 >= anchors.length) continue;
      final at = frameOf(out[i]);
      final prev = frameOf(out[i - 1]), next = frameOf(anchors[i + 1]);
      final lo = _max(_max(at - window, prev + side), side);
      final hi = _min(_min(at + window, next - side), target.length - side);
      if (lo > hi) continue;

      // How unevenly placing the barline at t paces the bars either side:
      // |log| of the ratio of their audio-per-score rates, 0 when steady.
      final scoreBefore = anchors[i].scoreMs - anchors[i - 1].scoreMs;
      final scoreAfter = anchors[i + 1].scoreMs - anchors[i].scoreMs;
      if (scoreBefore <= 0 || scoreAfter <= 0) continue;
      double unevenness(int t) => math
          .log(((t - prev) / scoreBefore) / ((next - t) / scoreAfter))
          .abs();
      final allowed = unevenness(at.clamp(lo, hi));

      double score(int t) {
        var s = 0.0;
        for (var k = 1; k <= side; k++) {
          s += _dot(target[t - k], outgoing) + _dot(target[t + k - 1], incoming);
        }
        return s;
      }

      var best = at.clamp(lo, hi);
      var bestScore = score(best);
      for (var t = lo; t <= hi; t++) {
        if (unevenness(t) > allowed) continue;
        final s = score(t);
        if (s > bestScore) {
          best = t;
          bestScore = s;
        }
      }
      out[i] = ScoreAudioAnchor(
          anchors[i].scoreMs, (targetStartFrame + best) * hopSeconds);
    }
    return out;
  }

  static bool _isSilent(Float64List v) => !v.any((x) => x > 0);

  static double _dot(Float64List a, Float64List b) {
    var d = 0.0;
    for (var k = 0; k < a.length; k++) {
      d += a[k] * b[k];
    }
    return d;
  }

  static int _max(int a, int b) => a > b ? a : b;
  static int _min(int a, int b) => a < b ? a : b;

  /// Anchor count below which [hasCompressedRun] won't attempt outlier
  /// detection — too few segments for a rolling-median comparison to mean
  /// anything.
  static const _minAnchorsForDetection = 6;

  /// True if the raw DTW path squeezed two or more consecutive anchors
  /// together rather than genuinely tracking the audio — see
  /// docs/audio-sync-dtw-anchor-compression.md. [anchors] must be in
  /// performance order (as built by [align], strictly increasing in
  /// [ScoreAudioAnchor.scoreMs]).
  ///
  /// When the score paces evenly but the DTW cost matrix has little to
  /// discriminate on for a couple of consecutive measures (e.g. a repeated
  /// melodic cell), the path can advance many reference frames while barely
  /// advancing through the target audio, so two or more consecutive segments'
  /// audio-per-score pace collapses to a fraction of the surrounding pace.
  ///
  /// This used to make [align] discard the anchor(s) sandwiched between such
  /// a run and silently re-interpolate across the gap. The one confirmed
  /// occurrence of this pattern turned out to be a genuinely wrong score (an
  /// unsupported first/second ending had produced extra, duplicate measures),
  /// not a DTW quirk — discarding anchors was masking a score bug rather than
  /// fixing an alignment one. So this now only flags the pattern; nothing is
  /// discarded, and the caller is expected to surface [alignmentReviewMessage]
  /// to the user instead.
  ///
  /// An isolated single flagged segment (not part of a run of 2+) doesn't
  /// count: with only one bad segment there's no way to tell which of its two
  /// endpoint anchors is at fault.
  static bool hasCompressedRun(
    List<ScoreAudioAnchor> anchors, {
    double outlierRatio = 0.6,
    int medianWindowRadius = 3,
  }) {
    final n = anchors.length;
    if (n < _minAnchorsForDetection) return false;

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

    for (var i = 1; i < n - 1; i++) {
      if (flagged[i] && flagged[i + 1]) return true;
    }
    return false;
  }

  /// Shortest window [AudioScoreAutoAligner.alignChroma] will honour. Anything
  /// shorter cannot hold a performance, so it is far likelier to be a typo (or
  /// a figure measured against a different file) than an instruction, and the
  /// answer that loses least is to fall back to inference over the whole
  /// recording rather than to align a piece against half a second of audio.
  static const double minContentWindowSeconds = 1.0;

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

/// The slice of a [ChromaSequence] the user says the performance occupies,
/// plus the frame index it starts at so anchors can be put back into real
/// audio time.
///
/// Trimming happens at the chroma level rather than on the samples so that the
/// extractor still sees the whole recording: its stationary-noise profile (see
/// [AudioChromaExtractor.noiseSubtractionFactor]) is a percentile over every
/// frame, and estimating a hum from a few seconds of music is worse than
/// estimating it from the lead-in that was cut.
class _ContentWindow {
  final int startFrame;
  final List<Float64List> frames;

  const _ContentWindow(this.startFrame, this.frames);

  /// The whole sequence when neither bound is given, or when what was given
  /// doesn't describe a usable span of this particular recording — see
  /// [AudioScoreAutoAligner.minContentWindowSeconds].
  factory _ContentWindow.of(
      ChromaSequence chroma, double? startSeconds, double? endSeconds) {
    final whole = _ContentWindow(0, chroma.frames);
    if (startSeconds == null && endSeconds == null) return whole;

    final total = chroma.frames.length;
    final first = startSeconds == null
        ? 0
        : (startSeconds / chroma.hopSeconds).floor().clamp(0, total);
    final last = endSeconds == null
        ? total
        : (endSeconds / chroma.hopSeconds).ceil().clamp(0, total);

    final minFrames =
        AudioScoreAutoAligner.minContentWindowSeconds ~/ chroma.hopSeconds;
    if (last - first < minFrames) return whole;

    return _ContentWindow(first, chroma.frames.sublist(first, last));
  }
}

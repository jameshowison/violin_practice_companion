import 'dart:typed_data';

import 'chroma_vector.dart';
import 'score_timing.dart';

/// A symbolic "reference" chroma feature sequence built directly from the
/// score's own note data — no audio synthesis needed. Frame `k`'s vector has
/// weight in pitch class `p` whenever a note of pitch class `p` is sounding
/// at time `k * hopSeconds` in the score's generated (arbitrary-tempo)
/// timeline ([TimedScore]).
///
/// [measureOnsetSeconds]/[measureNumbers] are carried straight through from
/// [TimedScore] — same array shape, same repeat-expanded performance order —
/// so a caller can read off each performed measure's frame index directly.
class ScoreChromaReference {
  final List<Float64List> frames;
  final double hopSeconds;
  final List<double> measureOnsetSeconds;
  final List<int> measureNumbers;

  /// 1 on the frame where a note starts (a repeated note too), else 0 — the
  /// score's side of [ChromaSequence.onsets].
  final Float64List onsets;

  const ScoreChromaReference({
    required this.frames,
    required this.onsets,
    required this.hopSeconds,
    required this.measureOnsetSeconds,
    required this.measureNumbers,
  });
}

class ScoreChromaReferenceBuilder {
  ScoreChromaReferenceBuilder({this.ringSeconds = 1.0});

  /// How long a note keeps sounding into a rest that follows it.
  ///
  /// The score says a note stops at the end of its value; a string doesn't.
  /// An open-string double stop written as an eighth and rests rings on for a
  /// second or more (the ff G-D chord in a Trepak teacher video took ~1.3 s
  /// to fade). With the rest silent in the reference, the ring matched
  /// nothing there, so the chord's place was a near tie that a 20 ms
  /// difference in how the video was decoded moved by 0.8 s — the bar and
  /// everything after it lit late on the iPad. Rung on, the reference sounds
  /// like the recording, and the chord lands within 0.05 s at 22.05, 44.1 and
  /// 48 kHz alike.
  ///
  /// Only into rest: a note followed by another note stops as written, and a
  /// long rest goes silent after the ring.
  final double ringSeconds;

  /// Builds a chroma reference from [data] (a score laid out at one tempo),
  /// framed at [hopSeconds] — this should match the hop used for the
  /// real-audio chroma extraction, so DTW compares frame-for-frame at the
  /// same time resolution.
  ScoreChromaReference build(TimedScore data, double hopSeconds) {
    final frameCount = (data.totalDurationSeconds / hopSeconds).ceil() + 1;
    final frames = List.generate(frameCount, (_) => Float64List(kChromaBins));
    final onsets = Float64List(frameCount);

    for (final note in data.notes) {
      final pitchClass = note.midiNote % 12;
      final startFrame =
          (note.onsetSeconds / hopSeconds).floor().clamp(0, frameCount - 1);
      onsets[(note.onsetSeconds / hopSeconds).round().clamp(0, frameCount - 1)] =
          1;
      final endFrame =
          (note.offsetSeconds / hopSeconds).ceil().clamp(0, frameCount - 1);
      for (var f = startFrame; f <= endFrame; f++) {
        frames[f][pitchClass] += 1.0;
      }
    }
    // Each note rings on into the rest after it (see [ringSeconds]).
    if (ringSeconds > 0) {
      final ring = (ringSeconds / hopSeconds).round();
      final silent = [for (final f in frames) !f.any((x) => x > 0)];
      for (final note in data.notes) {
        final endFrame =
            (note.offsetSeconds / hopSeconds).ceil().clamp(0, frameCount - 1);
        for (var f = endFrame + 1; f <= endFrame + ring && f < frameCount; f++) {
          if (!silent[f]) break;
          frames[f][note.midiNote % 12] += 1.0;
        }
      }
    }
    for (final frame in frames) {
      l2NormalizeInPlace(frame);
    }

    return ScoreChromaReference(
      frames: frames,
      onsets: onsets,
      hopSeconds: hopSeconds,
      measureOnsetSeconds: data.measureOnsetSeconds,
      measureNumbers: data.measureNumbers,
    );
  }
}

import 'dart:typed_data';

import '../models/parsed_piece.dart';
import 'chroma_vector.dart';
import 'midi_generator.dart';

/// A symbolic "reference" chroma feature sequence built directly from the
/// score's own note data — no audio synthesis needed. Frame `k`'s vector has
/// weight in pitch class `p` whenever a note of pitch class `p` is sounding
/// at time `k * hopSeconds` in the score's generated (arbitrary-tempo)
/// timeline, per [MidiGenerator.generate].
///
/// [measureOnsetSeconds]/[measureNumbers] are carried straight through from
/// [MidiData] — same array shape, same repeat-expanded performance order —
/// so a caller can read off each performed measure's frame index directly.
class ScoreChromaReference {
  final List<Float64List> frames;
  final double hopSeconds;
  final List<double> measureOnsetSeconds;
  final List<int> measureNumbers;

  const ScoreChromaReference({
    required this.frames,
    required this.hopSeconds,
    required this.measureOnsetSeconds,
    required this.measureNumbers,
  });
}

class ScoreChromaReferenceBuilder {
  final MidiGenerator _midiGenerator;

  ScoreChromaReferenceBuilder(this._midiGenerator);

  /// Builds a chroma reference at [bpm], framed at [hopSeconds] — this
  /// should match the hop used for the real-audio chroma extraction, so DTW
  /// compares frame-for-frame at the same time resolution.
  ScoreChromaReference build(ParsedPiece piece, int bpm, double hopSeconds) {
    final data = _midiGenerator.generate(piece, bpm);
    final frameCount = (data.totalDurationSeconds / hopSeconds).ceil() + 1;
    final frames = List.generate(frameCount, (_) => Float64List(kChromaBins));

    for (final note in data.notes) {
      final pitchClass = note.midiNote % 12;
      final startFrame =
          (note.onsetSeconds / hopSeconds).floor().clamp(0, frameCount - 1);
      final endFrame =
          (note.offsetSeconds / hopSeconds).ceil().clamp(0, frameCount - 1);
      for (var f = startFrame; f <= endFrame; f++) {
        frames[f][pitchClass] += 1.0;
      }
    }
    for (final frame in frames) {
      l2NormalizeInPlace(frame);
    }

    return ScoreChromaReference(
      frames: frames,
      hopSeconds: hopSeconds,
      measureOnsetSeconds: data.measureOnsetSeconds,
      measureNumbers: data.measureNumbers,
    );
  }
}

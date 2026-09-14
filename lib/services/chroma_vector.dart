import 'dart:math' as math;
import 'dart:typed_data';

/// Pitch-class count used throughout the audio/score alignment pipeline —
/// one bin per semitone of the chromatic scale (C=0 .. B=11), octave-folded.
const int kChromaBins = 12;

/// Scales [v] in place to unit L2 norm, so cosine distance between two
/// chroma vectors reduces to `1 - dot(a, b)`. Leaves an all-zero vector
/// (silence, or a frame with no energy in range) untouched.
void l2NormalizeInPlace(Float64List v) {
  var sumSq = 0.0;
  for (final x in v) {
    sumSq += x * x;
  }
  if (sumSq <= 1e-12) return;
  final norm = math.sqrt(sumSq);
  for (var i = 0; i < v.length; i++) {
    v[i] /= norm;
  }
}

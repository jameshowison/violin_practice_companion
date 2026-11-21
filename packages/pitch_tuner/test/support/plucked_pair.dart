// A copy of the app's test/support/plucked_pair.dart, whose screen tests
// pluck the same pair; a test helper can't be shared across packages.

import 'dart:math' as math;
import 'dart:typed_data';

/// Sample rate of [pluck]'s audio.
const pluckRate = 48000;

/// A plucked pair: two strings at [hz] and [cents] above it, each with three
/// harmonics, dying away over a couple of seconds, after 0.1 s of quiet.
/// [second] scales the other string (0: only one string sounds).
Float32List pluck(double hz, double cents, {double second = 1, double seconds = 3, int seed = 1}) {
  final rnd = math.Random(seed);
  final n = (seconds * pluckRate).round();
  final out = Float32List(n);
  final hz2 = hz * math.pow(2, cents / 1200);
  for (var i = 0; i < n; i++) {
    final t = i / pluckRate - 0.1;
    var v = (rnd.nextDouble() - 0.5) * 2e-4; // the room
    if (t >= 0) {
      for (final (h, a) in [(1, 0.20), (2, 0.10), (3, 0.06)]) {
        final decay = math.exp(-t * (0.9 + 0.5 * h));
        v += a * decay * (math.sin(2 * math.pi * h * hz * t) + second * math.sin(2 * math.pi * h * hz2 * t + h));
      }
    }
    out[i] = v * 0.5;
  }
  return out;
}


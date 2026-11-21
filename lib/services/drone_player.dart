// The tuner's drone: a target pitch rendered once to a WAV (pitch_tuner's
// DroneTone) and played on a loop by just_audio. Never a live synth (the
// app's CLAUDE.md, "Audio on iOS").
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'drone_player_io.dart';

/// Sounds one pitch at a time, on a loop, until stopped.
///
/// Implemented in `drone_player_io.dart`; made through
/// [dronePlayerFactoryProvider].
abstract class DronePlayerBase {
  /// Sounds [hz] on a loop, in place of whatever was sounding. Renders the
  /// tone the first time a pitch is asked for, then plays it from the cache.
  Future<void> play(double hz);

  /// Stops the tone. Safe to call when nothing is sounding.
  Future<void> stop();

  /// Stops, and releases the player for good.
  Future<void> dispose();
}

/// Makes the tuner's drone player. Overridden in tests with a fake.
final dronePlayerFactoryProvider =
    Provider<DronePlayerBase Function()>((_) => DronePlayer.new);

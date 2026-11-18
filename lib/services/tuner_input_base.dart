import 'dart:typed_data';

import 'package:string_tuner/string_tuner.dart';

/// One pitch reading from the microphone.
class TunerFrame {
  const TunerFrame(this.at, this.pitch);

  /// Time since the microphone started, at the end of the analysed frame.
  final Duration at;

  /// The estimate, or null when the frame was silent.
  final PitchEstimate? pitch;
}

/// The microphone was refused.
class TunerMicDenied implements Exception {
  const TunerMicDenied();
  @override
  String toString() => 'Microphone permission was not granted.';
}

/// Listens to the microphone and reports pitch readings, about 90 a second.
///
/// Implemented in `tuner_input_io.dart` (`record`'s PCM stream, analysed on a
/// background isolate); made through `tuner_input.dart`.
abstract class TunerInputBase {
  /// Whether this platform can listen at all.
  bool get isSupported;

  /// Starts listening, searching [minHz]..[maxHz]. Throws [TunerMicDenied]
  /// when permission is refused. Calling it again restarts with the new
  /// range.
  Future<Stream<TunerFrame>> start({required double minHz, required double maxHz});

  /// Stops listening. Safe to call when not started.
  Future<void> stop();

  /// Stops, and releases the microphone and the worker for good.
  Future<void> dispose();

  /// Called with every chunk of raw audio (mono 16-bit PCM at
  /// [TunerFrame]'s clock, from the first sample), for the developer's
  /// session recording (tuner_recording.dart). Null to skip.
  set onPcm(void Function(Uint8List pcm)? f);
}

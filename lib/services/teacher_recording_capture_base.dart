import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Records a silent video clip and a synchronized WAV mic recording of a
/// teacher demonstrating a piece ("teacher demo"). Video and audio are
/// captured by two independent recorders rather than one video-with-audio
/// file: this app has no mp3/mp4/aac decoder anywhere (see
/// audio_chroma_features.dart), only WAV, so the DTW alignment needs its own
/// dedicated WAV capture regardless of what the video file contains.
///
/// Gated to iOS/Android — see teacher_recording_capture_io.dart for why.
abstract class TeacherRecordingCaptureBase {
  /// False on any platform/build where recording can't work at all (checked
  /// before ever calling [initialize] — the web stub returns false and
  /// throws from every other method).
  bool get isSupported;

  /// Opens the camera (rear-facing by default) and checks microphone
  /// permission. Throws if unsupported, no camera is available, or
  /// permission is denied.
  Future<void> initialize();

  /// A live camera preview widget — a loading placeholder before the camera
  /// finishes opening.
  Widget buildPreview();

  /// Switches to the next available camera (e.g. front/rear).
  Future<void> flipCamera();

  /// Starts video (silent) and mic-audio (WAV) recording together for
  /// [pieceId], noting each stream's own start time for the AV-offset
  /// calculation [stop] returns.
  Future<void> start(String pieceId);

  /// Stops both recordings and returns their persisted paths, the raw WAV
  /// bytes (for immediate DTW alignment, without a second file read), and
  /// the measured AV offset.
  Future<TeacherRecordingCaptureResult> stop();

  Future<void> dispose();
}

/// [avOffsetMs] is video-start-minus-audio-start, in milliseconds: during
/// synced playback, video position = audio position + [avOffsetMs].
class TeacherRecordingCaptureResult {
  final String videoPath;
  final String audioPath;
  final int avOffsetMs;
  final Uint8List wavBytes;

  const TeacherRecordingCaptureResult({
    required this.videoPath,
    required this.audioPath,
    required this.avOffsetMs,
    required this.wavBytes,
  });
}

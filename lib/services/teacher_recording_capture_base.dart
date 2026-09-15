import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Records a silent video clip and a synchronized WAV mic recording of a
/// teacher demonstrating a piece ("teacher demo").
///
/// Video and audio are captured by two independent recorders rather than as
/// one video-with-audio file. That was originally forced: the app could decode
/// WAV and nothing else, so the DTW alignment needed its own dedicated WAV
/// capture whatever the video contained. [AudioDecoder] has since removed the
/// constraint — an imported mp4 is now aligned straight from its own audio
/// track — but the two-recorder capture is kept, because a WAV written by the
/// mic recorder is a better analysis source than a compressed track muxed into
/// a video, and because the AV offset it measures is already handled
/// everywhere downstream.
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

  /// Starts video (silent) and mic-audio (WAV) recording together into
  /// [mediaId]'s own folder under [pieceId], noting each stream's own start
  /// time for the AV-offset calculation [stop] returns.
  ///
  /// The medium's id is supplied rather than derived from the piece so that a
  /// second take is a second medium instead of overwriting the first — which
  /// is what happened while a piece could hold exactly one recording.
  Future<void> start(String pieceId, String mediaId);

  /// Stops both recordings and returns their persisted paths, the raw WAV
  /// bytes (for immediate DTW alignment, without a second file read), and
  /// the measured AV offset.
  Future<TeacherRecordingCaptureResult> stop();

  Future<void> dispose();
}

/// [avOffsetMs] is video-start-minus-audio-start, in milliseconds: during
/// synced playback, video position = audio position + [avOffsetMs].
///
/// Both paths are **relative to the documents directory**, ready to go
/// straight into a [MediaRef]. They used to be absolute, and were persisted
/// that way — see [MediaRef]'s doc comment for what that cost.
class TeacherRecordingCaptureResult {
  final String videoRelativePath;
  final String audioRelativePath;
  final int avOffsetMs;
  final Uint8List wavBytes;

  const TeacherRecordingCaptureResult({
    required this.videoRelativePath,
    required this.audioRelativePath,
    required this.avOffsetMs,
    required this.wavBytes,
  });
}

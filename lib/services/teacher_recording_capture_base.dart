import 'package:flutter/widgets.dart';

/// Records a teacher demonstrating a piece ("teacher demo") as one video
/// with sound, which is then stored and aligned exactly as an imported video
/// is: the one file is the medium's audio, analysis source and video.
///
/// It used to be two recorders, a silent video and a separate WAV from the
/// mic, because the app could once decode WAV and nothing else. Once
/// `AudioDecoder` could read a video's own audio track that bought nothing: an
/// imported phone video aligns as well, and one file has no offset between
/// picture and sound to estimate from two start times. The WAV recorder
/// (`record`) also set its own audio session over the app's.
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

  /// Starts recording video with sound, to be kept in [mediaId]'s own folder
  /// under [pieceId].
  ///
  /// The medium's id is supplied rather than derived from the piece so that a
  /// second take is a second medium instead of overwriting the first — which
  /// is what happened while a piece could hold exactly one recording.
  Future<void> start(String pieceId, String mediaId);

  /// Stops recording and moves the video into the medium's folder.
  Future<TeacherRecordingCaptureResult> stop();

  Future<void> dispose();
}

/// Where [TeacherRecordingCaptureBase.stop] put the recording.
///
/// [videoRelativePath] is **relative to the documents directory**, ready to go
/// straight into a `MediaRef` (absolute paths were once persisted — see
/// `MediaRef`'s doc comment for what that cost); [videoPath] is the same file,
/// absolute, for decoding it straight away.
class TeacherRecordingCaptureResult {
  final String videoRelativePath;
  final String videoPath;

  const TeacherRecordingCaptureResult({
    required this.videoRelativePath,
    required this.videoPath,
  });
}

import 'package:flutter/widgets.dart';

import 'teacher_recording_capture_base.dart';

/// Web stub. See [TeacherRecordingCaptureBase]'s doc comment for why teacher
/// demo recording is iOS/Android only.
class TeacherRecordingCapture implements TeacherRecordingCaptureBase {
  static const _unsupportedMessage =
      'Recording a teacher demo is only available on iOS and Android.';

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() => throw UnsupportedError(_unsupportedMessage);

  @override
  Widget buildPreview() => const SizedBox.shrink();

  @override
  Future<void> flipCamera() async {}

  @override
  Future<void> start(String pieceId) =>
      throw UnsupportedError(_unsupportedMessage);

  @override
  Future<TeacherRecordingCaptureResult> stop() =>
      throw UnsupportedError(_unsupportedMessage);

  @override
  Future<void> dispose() async {}
}

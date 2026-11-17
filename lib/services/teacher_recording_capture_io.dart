import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'media_paths.dart';
import 'teacher_recording_capture_base.dart';

/// Mobile implementation: `camera` records video with sound (AAC), the one
/// file a teacher demo keeps — see [TeacherRecordingCaptureBase].
///
/// The camera asks for the audio session the app already runs in
/// (play-and-record, A2DP, AirPlay, default to speaker), so recording leaves
/// playback as it was; the `record` plugin this replaced set its own.
///
/// iOS/Android only: `camera` (pubspec.yaml) declares no macOS support, and
/// recordings are persisted as real file-system paths under the app's
/// documents directory, which has no web equivalent in this app.
class TeacherRecordingCapture implements TeacherRecordingCaptureBase {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _lensIndex = 0;

  // Both forms are kept: the file must be moved somewhere real, and what gets
  // persisted must be relative (see [MediaRef]).
  String? _videoRelativePath;
  String? _videoPath;

  @override
  bool get isSupported => Platform.isIOS || Platform.isAndroid;

  @override
  Future<void> initialize() async {
    if (!isSupported) {
      throw UnsupportedError(
          'Recording a teacher demo is only available on iOS and Android.');
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No camera is available on this device.');
    }
    _cameras = cameras;
    _lensIndex =
        cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
    if (_lensIndex < 0) _lensIndex = 0;
    try {
      await _openController(cameras[_lensIndex]);
    } on CameraException catch (e) {
      if (e.code.startsWith('AudioAccess')) {
        throw StateError(
            'Microphone permission is required to record a teacher demo.');
      }
      rethrow;
    }
  }

  Future<void> _openController(CameraDescription description) async {
    await _controller?.dispose();
    final controller = CameraController(
      description,
      // 720p: what an imported video is shrunk to (VideoShrinker), so a
      // demo and an import end up alike.
      ResolutionPreset.high,
      enableAudio: true,
    );
    await controller.initialize();
    _controller = controller;
  }

  @override
  Widget buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return CameraPreview(controller);
  }

  @override
  Future<void> flipCamera() async {
    if (_cameras.length < 2) return;
    _lensIndex = (_lensIndex + 1) % _cameras.length;
    await _openController(_cameras[_lensIndex]);
  }

  @override
  Future<void> start(String pieceId, String mediaId) async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('Camera is not initialized — call initialize() first.');
    }
    final relativeFolder = mediaFolderFor(pieceId, mediaId);
    final folder = Directory(await resolveMediaPath(relativeFolder));
    await folder.create(recursive: true);
    _videoRelativePath = '$relativeFolder/video.mp4';
    _videoPath = await resolveMediaPath(_videoRelativePath!);
    await controller.startVideoRecording();
  }

  @override
  Future<TeacherRecordingCaptureResult> stop() async {
    final controller = _controller;
    final videoPath = _videoPath;
    if (controller == null || videoPath == null) {
      throw StateError('start() was not called before stop().');
    }

    final xfile = await controller.stopVideoRecording();
    final dest = File(videoPath);
    if (await dest.exists()) await dest.delete();
    await File(xfile.path).copy(videoPath);
    // Best-effort cleanup of the plugin's own temp copy — a failure here
    // leaves an orphaned temp file, not a broken recording.
    unawaited(File(xfile.path).delete().catchError((_) => File(xfile.path)));

    return TeacherRecordingCaptureResult(
      videoRelativePath: _videoRelativePath!,
      videoPath: videoPath,
    );
  }

  @override
  Future<void> dispose() async {
    await _controller?.dispose();
  }
}

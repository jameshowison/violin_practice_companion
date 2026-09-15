import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'teacher_recording_capture_base.dart';

/// Mobile implementation: `camera` records video-only (`enableAudio: false`
/// — see [TeacherRecordingCaptureBase]'s doc comment), `record` captures mic
/// audio straight to WAV via [AudioEncoder.wav]. Both are started back to
/// back, not atomically, so [stop] reports the measured gap between their
/// actual start times rather than assuming zero.
///
/// iOS/Android only: `camera` (pubspec.yaml) declares no macOS support, and
/// recordings are persisted as real file-system paths under the app's
/// documents directory, which has no web equivalent in this app.
class TeacherRecordingCapture implements TeacherRecordingCaptureBase {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _lensIndex = 0;
  final AudioRecorder _recorder = AudioRecorder();

  DateTime? _videoStartedAt;
  DateTime? _audioStartedAt;
  String? _videoPath;
  String? _audioPath;

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
    await _openController(cameras[_lensIndex]);
    final micGranted = await _recorder.hasPermission();
    if (!micGranted) {
      throw StateError(
          'Microphone permission is required to record a teacher demo.');
    }
  }

  Future<void> _openController(CameraDescription description) async {
    await _controller?.dispose();
    final controller = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: false,
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
  Future<void> start(String pieceId) async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('Camera is not initialized — call initialize() first.');
    }
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/teacher_recordings/$pieceId');
    await folder.create(recursive: true);
    _videoPath = '${folder.path}/video.mp4';
    _audioPath = '${folder.path}/audio.wav';

    await controller.startVideoRecording();
    _videoStartedAt = DateTime.now();
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.wav),
        path: _audioPath!);
    _audioStartedAt = DateTime.now();
  }

  @override
  Future<TeacherRecordingCaptureResult> stop() async {
    final controller = _controller;
    final videoPath = _videoPath;
    final audioPath = _audioPath;
    if (controller == null || videoPath == null || audioPath == null) {
      throw StateError('start() was not called before stop().');
    }

    final xfile = await controller.stopVideoRecording();
    await _recorder.stop();

    final dest = File(videoPath);
    if (await dest.exists()) await dest.delete();
    await File(xfile.path).copy(videoPath);
    // Best-effort cleanup of the plugin's own temp copy — a failure here
    // leaves an orphaned temp file, not a broken recording.
    unawaited(File(xfile.path).delete().catchError((_) => File(xfile.path)));

    final wavBytes = await File(audioPath).readAsBytes();

    final videoStart = _videoStartedAt;
    final audioStart = _audioStartedAt;
    final avOffsetMs = (videoStart == null || audioStart == null)
        ? 0
        : videoStart.difference(audioStart).inMilliseconds;

    return TeacherRecordingCaptureResult(
      videoPath: videoPath,
      audioPath: audioPath,
      avOffsetMs: avOffsetMs,
      wavBytes: wavBytes,
    );
  }

  @override
  Future<void> dispose() async {
    await _controller?.dispose();
    await _recorder.dispose();
  }
}

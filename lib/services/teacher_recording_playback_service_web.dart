import 'package:flutter/foundation.dart';

import '../models/parsed_piece.dart';
import 'midi_generator.dart';
import 'playback_service_base.dart';
import 'teacher_recording_store.dart';

/// Web stub — teacher-demo recording/playback is iOS/Android only (see
/// teacher_recording_capture_base.dart). A teacher recording can never be
/// created on web, so `hasTeacherRecordingProvider` is always false there and
/// this class is never actually driven; it exists only so the shared call
/// sites in teacher_demo_controls.dart and providers.dart compile.
class TeacherRecordingPlaybackService extends PlaybackServiceBase {
  final ValueNotifier<bool> isAligning = ValueNotifier(false);
  final ValueNotifier<bool> alignmentLooksUncertain = ValueNotifier(false);
  final ValueNotifier<double> playbackSpeed = ValueNotifier(1.0);

  TeacherRecordingPlaybackService(super.generator,
      {TeacherRecordingStore? store});

  String? get videoPath => null;
  int get avOffsetMs => 0;
  Duration get rawAudioPosition => Duration.zero;

  Future<bool> load({required ParsedPiece piece, required String pieceId}) async =>
      false;

  Future<void> realign(
      {required ParsedPiece piece, required String pieceId}) async {}

  Future<void> setPlaybackSpeed(double speed) async {}

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {}

  @override
  void onStopped() {}

  @override
  void onTick(double playbackTime, MidiData data) {}

  @override
  void dispose() {
    super.dispose();
    isAligning.dispose();
    alignmentLooksUncertain.dispose();
    playbackSpeed.dispose();
  }
}

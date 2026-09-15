import 'package:flutter/material.dart';

import '../services/teacher_recording_playback_service.dart';

/// Web stub — never actually inserted into the tree in practice, since
/// `hasTeacherRecordingProvider` is always false on web (see
/// teacher_recording_capture_base.dart), but kept so the shared call site in
/// piece_detail_screen.dart compiles.
class FloatingVideoOverlay extends StatelessWidget {
  final TeacherRecordingPlaybackService service;

  const FloatingVideoOverlay({super.key, required this.service});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

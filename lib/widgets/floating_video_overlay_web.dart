import 'package:flutter/material.dart';

import '../services/media_playback_service.dart';

/// Web stub — never actually inserted into the tree in practice, since no
/// medium on web can have a video (recording is iOS/Android only and there is
/// nowhere to import a file to; see media_paths_web.dart), but kept so the
/// shared call site in piece_detail_screen.dart compiles.
class FloatingVideoOverlay extends StatelessWidget {
  final MediaPlaybackService service;

  const FloatingVideoOverlay({super.key, required this.service});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

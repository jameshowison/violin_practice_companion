import 'package:flutter/material.dart';

import '../services/media_playback_service.dart';

/// Web stub — never actually inserted into the tree in practice, since no
/// medium on web can have a video (recording is iOS/Android only and there is
/// nowhere to import a file to; see media_paths_web.dart), but kept so the
/// shared call site in piece_detail_screen.dart compiles.
class FloatingVideoOverlay extends StatelessWidget {
  final MediaPlaybackService service;

  final double toolbarHeight;
  final int startMeasure;
  final int startNote;
  final int startIndex;

  const FloatingVideoOverlay({
    super.key,
    required this.service,
    required this.toolbarHeight,
    this.startMeasure = 1,
    this.startNote = 0,
    this.startIndex = -1,
  });

  @override
  Widget build(BuildContext context) => const Positioned(width: 0, height: 0, child: SizedBox.shrink());
}

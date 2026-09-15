import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/playback_service_base.dart';
import '../services/teacher_recording_playback_service.dart';

/// Draggable, closable floating window showing the teacher-demo video,
/// placed as a direct child of the same `Stack` that holds the notation view
/// (see piece_detail_screen.dart). Kept in sync with [service]'s *real*
/// audio clock via periodic corrective seeks — not the score-highlight
/// clock, which is DTW-mapped and runs at a different local rate than the
/// actual recording.
class FloatingVideoOverlay extends StatefulWidget {
  final TeacherRecordingPlaybackService service;

  const FloatingVideoOverlay({super.key, required this.service});

  @override
  State<FloatingVideoOverlay> createState() => _FloatingVideoOverlayState();
}

class _FloatingVideoOverlayState extends State<FloatingVideoOverlay> {
  static const _size = Size(160, 120);
  static const _margin = 12.0;
  static const _driftThreshold = Duration(milliseconds: 100);

  VideoPlayerController? _controller;
  String? _loadedPath;
  String? _loadError;
  Offset? _offset;
  bool _closed = false;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _maybeLoad();
    _syncTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) => _resync());
  }

  @override
  void didUpdateWidget(covariant FloatingVideoOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeLoad();
  }

  void _maybeLoad() {
    final path = widget.service.videoPath;
    if (path == null || path == _loadedPath) return;
    _loadedPath = path;
    unawaited(_load(path));
  }

  Future<void> _load(String path) async {
    final old = _controller;
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
    } catch (error) {
      // A video the platform can't decode used to leave this as an unhandled
      // async error, with `_loadedPath` already latched to the failed path —
      // so the window sat on an indefinite spinner, said nothing about why,
      // and never retried even once the file was replaced. Found with an
      // HEVC recording on the iOS simulator, which has no HEVC decoder (a
      // phone plays the same file fine), but any unreadable or partly-written
      // capture would do the same.
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _loadedPath = null; // let a later rebuild try again
        _loadError = '$error';
      });
      return;
    }
    await controller.setVolume(0);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _loadError = null;
      _controller = controller;
    });
    await old?.dispose();
  }

  void _resync() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final service = widget.service;

    final playing = service.playbackState == PlaybackState.playing;
    if (controller.value.isPlaying != playing) {
      playing ? controller.play() : controller.pause();
    }

    final speed = service.playbackSpeed.value;
    if ((controller.value.playbackSpeed - speed).abs() > 0.001) {
      controller.setPlaybackSpeed(speed);
    }

    if (!playing) return;
    final target =
        service.rawAudioPosition + Duration(milliseconds: service.avOffsetMs);
    final clampedTarget = target.isNegative ? Duration.zero : target;
    if ((controller.value.position - clampedTarget).abs() > _driftThreshold) {
      controller.seekTo(clampedTarget);
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  double _clamp(double value, double max) => value.clamp(0, max < 0 ? 0 : max);

  @override
  Widget build(BuildContext context) {
    if (_closed) return const SizedBox.shrink();
    final screen = MediaQuery.sizeOf(context);
    final maxX = screen.width - _size.width;
    final maxY = screen.height - _size.height;
    final offset = _offset ??
        Offset(maxX - _margin, screen.height - _size.height - _margin * 3);
    final controller = _controller;

    return Positioned(
      left: _clamp(offset.dx, maxX),
      top: _clamp(offset.dy, maxY),
      width: _size.width,
      height: _size.height,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            final next = offset + details.delta;
            _offset = Offset(_clamp(next.dx, maxX), _clamp(next.dy, maxY));
          });
        },
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.black),
              if (controller != null && controller.value.isInitialized)
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: controller.value.size.width,
                    height: controller.value.size.height,
                    child: VideoPlayer(controller),
                  ),
                )
              else if (_loadError != null)
                // Say so, rather than spinning forever on a video that will
                // never load — see [_load].
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Center(
                    child: Text(
                      "Can't play this video",
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.white70),
                    ),
                  ),
                )
              else
                const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white70),
                  ),
                ),
              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: () => setState(() => _closed = true),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

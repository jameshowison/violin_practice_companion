import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../services/media_playback_service.dart';
import '../services/playback_service_base.dart';
import 'video_window_mode.dart';

/// The selected medium's video, in one of the places [VideoWindowMode] names:
///
/// * **Docked** (the default) — in the app bar's top-left corner, the bar's
///   full height, as wide as the video's shape needs. It covers the back
///   button, so leaving the piece means closing the video first. Left
///   because the count-in takes over the bar from the right, and the window
///   doesn't move when Play is pressed.
/// * **Floating** — tapping the docked window opens it over the music:
///   draggable, resizable from its corner to any size, with move-to-title-bar,
///   full-screen and close buttons that show only while hovered or for a few
///   seconds after a tap (a phone has no hover).
/// * **Hidden** — after close. The bottom bar's video toggle reopens it
///   where it was, docked or floating at the same place and size (see
///   media_controls.dart).
///
/// Placed as a direct child of a `Stack` that covers the whole screen —
/// app bar included (see piece_detail_screen.dart) — since the docked window
/// sits in the bar. Kept in sync with [service]'s *real* audio clock via
/// periodic corrective seeks — not the score-highlight clock, which is
/// DTW-mapped and runs at a different local rate than the actual recording.
/// Held still on the starting frame through a count-in, unless the count is
/// heard over the recording itself (its intro, from the top).
///
/// Shown for any medium that has one: an imported mp4/mov or a recorded
/// teacher demo, where the same file supplies both and the AV offset is zero
/// (an older demo may still be a silent video beside a separate WAV).
class FloatingVideoOverlay extends ConsumerStatefulWidget {
  final MediaPlaybackService service;

  /// Height of the app bar's toolbar, below the status bar.
  final double toolbarHeight;

  /// Where Play would start: the selected bar (and note, and pass), as
  /// passed to `play`. When it changes while paused, the video jumps there,
  /// so tapping a bar shows that moment of the recording.
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
  ConsumerState<FloatingVideoOverlay> createState() =>
      _FloatingVideoOverlayState();
}

class _FloatingVideoOverlayState extends ConsumerState<FloatingVideoOverlay> {
  static const _margin = 8.0;
  static const _minFloat = Size(120, 68);
  static const _controlsLinger = Duration(seconds: 3);
  static const _driftThreshold = Duration(milliseconds: 100);

  /// Shared with the full-screen page, which may see a reload.
  final _controller = ValueNotifier<VideoPlayerController?>(null);
  String? _loadedPath;
  String? _loadError;
  Timer? _syncTimer;

  /// True from the first tick of a count-in until it ends: the video holds
  /// its starting frame rather than running ahead of the music.
  bool _heldForCountIn = false;

  /// The floating window's frame, once the user has moved or resized it.
  Offset? _floatOffset;
  Size? _floatSize;

  /// The floating window's buttons: shown while hovered, or for a few
  /// seconds after a tap.
  bool _hovering = false;
  bool _tapShown = false;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    widget.service.videoPathNotifier.addListener(_maybeLoad);
    _maybeLoad();
    _syncTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) => _resync());
    widget.service.countInNotifier.addListener(_onCountIn);
  }

  @override
  void didUpdateWidget(covariant FloatingVideoOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.countInNotifier.removeListener(_onCountIn);
      widget.service.countInNotifier.addListener(_onCountIn);
      oldWidget.service.videoPathNotifier.removeListener(_maybeLoad);
      widget.service.videoPathNotifier.addListener(_maybeLoad);
    }
    _maybeLoad();
    if (oldWidget.startMeasure != widget.startMeasure ||
        oldWidget.startNote != widget.startNote ||
        oldWidget.startIndex != widget.startIndex) {
      if (widget.service.playbackState != PlaybackState.playing) _showStart();
    }
  }

  void _maybeLoad() {
    final path = widget.service.videoPath;
    if (path == null || path == _loadedPath) return;
    _loadedPath = path;
    unawaited(_load(path));
  }

  Future<void> _load(String path) async {
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
    } catch (error) {
      if (path != _loadedPath) {
        // Superseded while it was opening; the newer load reports its own.
        await controller.dispose();
        return;
      }
      // A video the platform can't decode used to leave this as an unhandled
      // async error, with `_loadedPath` already latched to the failed path —
      // so the window sat on an indefinite spinner, said nothing about why,
      // and never retried even once the file was replaced. Any unreadable or
      // partly-written capture does this. (It was first blamed on the iOS
      // simulator lacking an HEVC decoder, but it has one: on iOS 26.5 every
      // HEVC file in the dev library decodes and plays through AVPlayer.)
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _loadedPath = null; // let a later rebuild try again
        _loadError = '$error';
      });
      return;
    }
    await controller.setVolume(0);
    // A load that finishes after a newer one has started must not win: a
    // slow-opening previous video would otherwise land on top of the new one.
    if (!mounted || path != _loadedPath) {
      await controller.dispose();
      return;
    }
    setState(() => _loadError = null);
    final old = _controller.value;
    _controller.value = controller;
    await old?.dispose();
    _showStart();
  }

  /// Seeks the video to where Play would start, and leaves it paused there.
  void _showStart() {
    final controller = _controller.value;
    if (controller == null || !controller.value.isInitialized) return;
    final service = widget.service;
    final scoreSec = service.startOffsetFor(
        fromMeasure: widget.startMeasure,
        fromNote: widget.startNote,
        fromIndex: widget.startIndex);
    if (scoreSec == null) return;
    final target = service.audioPositionForScoreSeconds(scoreSec) +
        Duration(milliseconds: service.avOffsetMs);
    if (controller.value.isPlaying) controller.pause();
    controller.seekTo(target.isNegative ? Duration.zero : target);
  }

  void _onCountIn() {
    final counting = widget.service.countInNotifier.value != null;
    if (counting == _heldForCountIn) return;
    _heldForCountIn = counting;
    if (counting) _showStart();
  }

  void _resync() {
    final controller = _controller.value;
    if (controller == null || !controller.value.isInitialized) return;
    final service = widget.service;
    // Through a count-in the video holds its starting frame while the count
    // is over silence, and runs once the recording is heard (its intro).
    if (_heldForCountIn && !service.isSounding) return;

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
        service.heardAudioPosition +
        Duration(milliseconds: service.avOffsetMs);
    final clampedTarget = target.isNegative ? Duration.zero : target;
    if ((controller.value.position - clampedTarget).abs() > _driftThreshold) {
      controller.seekTo(clampedTarget);
    }
  }

  @override
  void dispose() {
    widget.service.countInNotifier.removeListener(_onCountIn);
    widget.service.videoPathNotifier.removeListener(_maybeLoad);
    _syncTimer?.cancel();
    _controlsTimer?.cancel();
    _controller.value?.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setMode(VideoWindowMode mode) {
    _controlsTimer?.cancel();
    _tapShown = false;
    _hovering = false;
    ref.read(videoWindowModeProvider.notifier).state = mode;
  }

  void _showControlsBriefly() {
    _controlsTimer?.cancel();
    setState(() => _tapShown = true);
    _controlsTimer = Timer(_controlsLinger, () {
      if (mounted) setState(() => _tapShown = false);
    });
  }

  void _openFullScreen() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FullScreenVideo(controller: _controller),
    ));
  }

  double get _aspect {
    final controller = _controller.value;
    return controller != null && controller.value.isInitialized
        ? controller.value.aspectRatio
        : 16 / 9;
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(videoWindowModeProvider);
    ref.watch(lastShownVideoModeProvider); // keeps it alive; see there
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);

    switch (mode) {
      case VideoWindowMode.hidden:
        return const Positioned(width: 0, height: 0, child: SizedBox.shrink());
      case VideoWindowMode.floating:
        return _buildFloating(context, screen, pad);
      case VideoWindowMode.docked:
        final height = widget.toolbarHeight;
        final width = (height * _aspect).clamp(height, screen.width * 0.4);
        return Positioned(
          key: const ValueKey('video_docked'),
          left: pad.left,
          top: pad.top,
          width: width,
          height: height,
          child: GestureDetector(
            onTap: () => _setMode(VideoWindowMode.floating),
            child: _videoSurface(context, BoxFit.cover),
          ),
        );
    }
  }

  Widget _buildFloating(BuildContext context, Size screen, EdgeInsets pad) {
    final barBottom = pad.top + widget.toolbarHeight;
    final maxW = screen.width - pad.horizontal;
    final maxH = screen.height - pad.top;
    final size = _floatSize ??
        () {
          var w = (screen.width * 0.55).clamp(160.0, 360.0);
          var h = w / _aspect;
          if (h > screen.height * 0.45) {
            h = screen.height * 0.45;
            w = h * _aspect;
          }
          return Size(w, h);
        }();
    final width = size.width.clamp(_minFloat.width, maxW);
    final height = size.height.clamp(_minFloat.height, maxH);

    final maxX = screen.width - pad.right - width;
    final maxY = screen.height - height;
    final offset = _floatOffset ?? Offset(maxX - _margin, barBottom + _margin);
    final left = offset.dx.clamp(pad.left, maxX < pad.left ? pad.left : maxX);
    final top = offset.dy.clamp(pad.top, maxY < pad.top ? pad.top : maxY);
    final controlsShown = _hovering || _tapShown;

    return Positioned(
      key: const ValueKey('video_floating'),
      left: left,
      top: top,
      width: width,
      height: height,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: _showControlsBriefly,
          onPanUpdate: (details) => setState(() {
            _floatOffset = Offset(left, top) + details.delta;
          }),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _videoSurface(context, BoxFit.contain),
                Positioned(
                  top: 0,
                  right: 0,
                  child: _Fade(
                    shown: controlsShown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RoundButton(
                          key: const ValueKey('video_to_bar'),
                          icon: Icons.north_west,
                          tooltip: 'Move to title bar',
                          onTap: () => _setMode(VideoWindowMode.docked),
                        ),
                        _RoundButton(
                          key: const ValueKey('video_fullscreen'),
                          icon: Icons.fullscreen,
                          tooltip: 'Full screen',
                          onTap: _openFullScreen,
                        ),
                        _RoundButton(
                          key: const ValueKey('video_dismiss'),
                          icon: Icons.close,
                          tooltip: 'Close video',
                          onTap: () {
                            _setMode(VideoWindowMode.floating);
                            hideVideo(ref);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                // Resize from the corner, to any size and shape — the video
                // letterboxes inside. Dragging keeps the buttons up.
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: _Fade(
                    shown: controlsShown,
                    child: GestureDetector(
                      key: const ValueKey('video_resize'),
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => _showControlsBriefly(),
                      onPanUpdate: (details) => setState(() {
                        _floatOffset = Offset(left, top);
                        _floatSize = Size(
                          (width + details.delta.dx)
                              .clamp(_minFloat.width, screen.width - pad.right - left),
                          (height + details.delta.dy)
                              .clamp(_minFloat.height, screen.height - top),
                        );
                      }),
                      onPanEnd: (_) => _showControlsBriefly(),
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.open_in_full,
                                size: 20,
                                color: Colors.white,
                                shadows: [Shadow(blurRadius: 4)]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Black box with the video fitted into it, an error, or a spinner.
  Widget _videoSurface(BuildContext context, BoxFit fit) {
    final controller = _controller.value;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (controller != null && controller.value.isInitialized)
          FittedBox(
            fit: fit,
            clipBehavior: Clip.hardEdge,
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
            padding: const EdgeInsets.all(4),
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
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white70),
            ),
          ),
      ],
    );
  }
}

/// Fades [child] in and out, and lets taps through it while faded out.
class _Fade extends StatelessWidget {
  const _Fade({required this.shown, required this.child});

  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: !shown,
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: child,
        ),
      );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton(
      {super.key, required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        // A 44pt target around the 36pt circle.
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: const BoxDecoration(
                color: Colors.black54, shape: BoxShape.circle),
            child: Icon(icon, size: 24, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// The same video, filling the screen. The overlay underneath keeps it in
/// sync with playback, so this only has to show it.
class _FullScreenVideo extends StatelessWidget {
  const _FullScreenVideo({required this.controller});

  final ValueListenable<VideoPlayerController?> controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: ValueListenableBuilder<VideoPlayerController?>(
              valueListenable: controller,
              builder: (context, c, _) => c == null || !c.value.isInitialized
                  ? const CircularProgressIndicator(color: Colors.white70)
                  : AspectRatio(
                      aspectRatio: c.value.aspectRatio,
                      child: VideoPlayer(c),
                    ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: _RoundButton(
                  key: const ValueKey('video_fullscreen_close'),
                  icon: Icons.fullscreen_exit,
                  tooltip: 'Exit full screen',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

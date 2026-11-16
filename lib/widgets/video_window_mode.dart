import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the selected medium's video is showing on the piece screen.
enum VideoWindowMode {
  /// In the app bar's top-left corner, the bar's full height. The default.
  docked,

  /// A movable, resizable window over the music.
  floating,

  /// Closed; the bottom bar's video toggle brings it back where it was.
  hidden,
}

/// Shared by the video overlay (which draws the video) and the bottom bar
/// (which offers to reopen it). Auto-disposed, so every piece opens docked.
final videoWindowModeProvider =
    StateProvider.autoDispose<VideoWindowMode>((_) => VideoWindowMode.docked);

/// Where the video was before it was last hidden, so showing it again puts it
/// back there. The floating window's own position and size are kept by the
/// overlay, which stays mounted while hidden — and which watches this, since
/// an auto-disposed provider nobody watches forgets its state at once.
final lastShownVideoModeProvider =
    StateProvider.autoDispose<VideoWindowMode>((_) => VideoWindowMode.docked);

/// Hides the video, remembering where it was.
void hideVideo(WidgetRef ref) {
  final mode = ref.read(videoWindowModeProvider);
  if (mode == VideoWindowMode.hidden) return;
  ref.read(lastShownVideoModeProvider.notifier).state = mode;
  ref.read(videoWindowModeProvider.notifier).state = VideoWindowMode.hidden;
}

/// Shows the video where it was when last hidden.
void showVideo(WidgetRef ref) {
  ref.read(videoWindowModeProvider.notifier).state =
      ref.read(lastShownVideoModeProvider);
}

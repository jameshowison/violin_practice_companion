import '../models/piece_media.dart';

/// Web stub: media files are unsupported there (see `media_paths_web.dart`),
/// so there is never a video to shrink.
class VideoShrinker {
  VideoShrinker._();
  static final VideoShrinker instance = VideoShrinker._();

  Future<void> applyFinishedShrinks() async {}
  void scheduleLaunchPass() {}
  void enqueue(String pieceId, PieceMedia media) {}
}

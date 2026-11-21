import 'package:flutter/services.dart';

/// The app's own native media helpers: `shrinkVideo` (video_shrinker_io.dart)
/// and `encodeAac` (rendered_score_cache_io.dart).
///
/// They once shared the decoder's channel. They are the app's, not the
/// decoder's: the decoder reads any file into PCM for alignment and is headed
/// for a library (`audio_decoder`, docs/family/libraries.md), while these two
/// write files in the app's own formats. Native halves:
/// `ios/Runner/MediaToolsPlugin.swift`, and on Android `MediaToolsPlugin.kt`
/// (which hands to `VideoShrinker` and `AacEncoder`), both registered by hand.
class MediaTools {
  MediaTools._();

  /// Matches the channel name registered in both native plugins.
  static const MethodChannel channel =
      MethodChannel('violin_practice_companion/media_tools');
}

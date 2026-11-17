// Re-encoding imported video happens in the native plugins and touches the
// documents directory, neither of which exists on the web build.
export 'video_shrinker_io.dart' if (dart.library.html) 'video_shrinker_web.dart';

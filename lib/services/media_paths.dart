// Resolving a [MediaRef] means touching the file system, which has no web
// equivalent — the web build serves bundled assets only. See
// media_paths_io.dart for the resolution rule and why it is a rule and not a
// stored string.
export 'media_paths_io.dart' if (dart.library.html) 'media_paths_web.dart';

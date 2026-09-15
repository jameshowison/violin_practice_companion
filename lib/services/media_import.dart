// Importing means picking a file off the device and copying it into the app's
// documents directory — neither of which exists on the web build. See
// media_paths_io.dart.
export 'media_import_io.dart' if (dart.library.html) 'media_import_web.dart';

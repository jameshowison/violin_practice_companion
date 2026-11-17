// Scratch files and unreferenced media live on the device's file system,
// which the web build doesn't have. See storage_cleanup_io.dart.
export 'storage_cleanup_io.dart' if (dart.library.html) 'storage_cleanup_web.dart';

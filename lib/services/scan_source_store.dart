// A scan's source images are files under the documents directory, which the
// web build doesn't have (and web can't scan anyway). See
// scan_source_store_io.dart.
export 'scan_source_store_io.dart' if (dart.library.html) 'scan_source_store_web.dart';

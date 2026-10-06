// The dev library is files pushed into the documents directory after install
// (scripts/push_dev_library.sh), and the web build has no documents directory.
// See dev_library_io.dart.
export 'dev_library_io.dart' if (dart.library.html) 'dev_library_web.dart';

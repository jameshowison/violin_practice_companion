// The dev library is files pushed into the documents directory after install
// (scripts/push_dev_library.sh); the web build has no documents directory, so
// it fetches a prefs bundle instead (scripts/push_dev_library_web.sh).
// See dev_library_io.dart and dev_library_bundle.dart.
export 'dev_library_io.dart' if (dart.library.html) 'dev_library_web.dart';

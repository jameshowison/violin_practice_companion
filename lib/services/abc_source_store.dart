// An imported tune's ABC text is a file under the documents directory, which
// the web build doesn't have. See abc_source_store_io.dart.
export 'abc_source_store_io.dart' if (dart.library.html) 'abc_source_store_web.dart';

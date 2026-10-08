// Debug builds write the last PDF printed to the documents directory, so an
// agent can pull it off a simulator (`simctl get_app_container … data`) and
// read the pages — the print and share sheets themselves are native UI that
// nothing can drive. The web build has no file system to write to.
export 'print_debug_dump_io.dart' if (dart.library.html) 'print_debug_dump_web.dart';

// Debug builds write the last PDF printed to the documents directory, so an
// agent can pull it off a simulator (`simctl get_app_container … data`) and
// read the pages — the print and share sheets themselves are native UI that
// nothing can drive.
export 'print_debug_dump_io.dart';

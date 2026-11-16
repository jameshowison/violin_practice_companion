// Sharing a piece writes and reads a zip of files under the documents
// directory, which the web build doesn't have. See piece_share_io.dart, and
// piece_share_bundle.dart for the format.
export 'piece_share_bundle.dart';
export 'piece_share_io.dart' if (dart.library.html) 'piece_share_web.dart';

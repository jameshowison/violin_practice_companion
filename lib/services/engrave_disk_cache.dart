// The engraver's results, kept on disk so a piece opened in an earlier launch
// opens without engraving again (see `VerovioEngraver.engrave`). The web build
// has no file system; there it is a no-op and only the in-memory cache applies.
export 'engrave_disk_cache_io.dart' if (dart.library.html) 'engrave_disk_cache_web.dart';

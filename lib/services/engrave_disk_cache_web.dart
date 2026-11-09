/// No file system on the web; every lookup misses.
Future<String?> readEngrave(String key) async => null;

/// No file system on the web; nothing is kept.
Future<void> writeEngrave(String key, String json) async {}

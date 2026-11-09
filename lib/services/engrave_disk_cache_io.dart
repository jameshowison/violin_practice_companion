import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../build_info.dart';

/// One file per engrave key, in the OS cache directory (which the OS may purge
/// — every entry is reproducible, so losing one only costs an engrave).
///
/// Entries are only valid for the code that produced them: `_buildScore`'s
/// post-processing changes often, and a stale entry would quietly show the old
/// output. So the folder is stamped with the app binaries — the executable
/// and, on iOS, `App.framework/App`, which holds the compiled Dart and changes
/// even when the executable isn't relinked — by path and mtime (a reinstall
/// changes both), plus the debug build stamp; it's wiped when any of them moves.
const _maxEntries = 80; // a few hundred KB each

Future<Directory?>? _dir;

Future<Directory?> _open() => _dir ??= () async {
      try {
        final base = await getApplicationCacheDirectory();
        final dir = Directory('${base.path}/engraves');
        final exe = File(Platform.resolvedExecutable);
        final dart = File('${exe.parent.path}/Frameworks/App.framework/App');
        String sig(File f) => f.existsSync()
            ? '${f.path}@${f.statSync().modified.millisecondsSinceEpoch}'
            : '-';
        final stamp = '$kBuildRef|${sig(exe)}|${sig(dart)}';
        final stampFile = File('${dir.path}/.stamp');
        if (!dir.existsSync() ||
            !stampFile.existsSync() ||
            stampFile.readAsStringSync() != stamp) {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
          dir.createSync(recursive: true);
          stampFile.writeAsStringSync(stamp);
        }
        return dir;
      } catch (e) {
        debugPrint('[engrave cache] disabled: $e');
        return null;
      }
    }();

Future<String?> readEngrave(String key) async {
  final dir = await _open();
  if (dir == null) return null;
  final file = File('${dir.path}/$key.json');
  try {
    final json = await file.readAsString();
    // Touch, so pruning drops the least recently USED entries.
    file.setLastModified(DateTime.now()).ignore();
    return json;
  } on FileSystemException {
    return null;
  }
}

Future<void> writeEngrave(String key, String json) async {
  final dir = await _open();
  if (dir == null) return;
  try {
    await File('${dir.path}/$key.json').writeAsString(json);
    final entries = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    if (entries.length <= _maxEntries) return;
    entries.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    for (final f in entries.take(entries.length - _maxEntries)) {
      f.deleteSync();
    }
  } catch (e) {
    debugPrint('[engrave cache] write failed: $e');
  }
}

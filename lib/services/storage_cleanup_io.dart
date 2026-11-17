import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scan_source_store_io.dart';

/// Removes the files the app's plugins leave behind, and media files nothing
/// refers to any more.
///
/// Measured on a dev iPad in 2026-11: of 916 MB of app data, ~330 MB was this
/// — the file picker's 159 MB copy of an imported video (the app had already
/// copied it into `media/`), scanner and cropper intermediates in three
/// directories, and a 36 MB video no medium named. None of it is user data,
/// and the plugins never delete any of it.
///
/// Two halves: [deleteScratch] at the moment a scratch file has been read, so
/// nothing new piles up, and [sweep] at launch for what is already there.
class StorageCleanup {
  StorageCleanup({
    Directory? documents,
    List<Directory>? scratchDirectories,
    DateTime Function()? now,
  })  : _documents = documents,
        _scratch = scratchDirectories,
        _now = now ?? DateTime.now;

  static final StorageCleanup instance = StorageCleanup();

  /// A leftover must be at least this old before [sweep] removes it, so it
  /// can never pull a file out from under an import, scan or share that is
  /// still running.
  static const Duration minimumAge = Duration(days: 1);

  static const Duration launchSweepDelay = Duration(seconds: 30);

  Directory? _documents;
  List<Directory>? _scratch;
  final DateTime Function() _now;

  Future<Directory> _docs() async =>
      _documents ??= await getApplicationDocumentsDirectory();

  /// Where plugins put scratch copies: `tmp/` on iOS (Dart's
  /// [Directory.systemTemp]; the file picker, image cropper and photo picker
  /// write there) and path_provider's temporary directory (`Library/Caches` on
  /// iOS, the cache directory on Android; this app's own OMR page copies).
  Future<List<Directory>> _scratchDirs() async {
    if (_scratch != null) return _scratch!;
    final dirs = <String, Directory>{};
    for (final d in [Directory.systemTemp, await getTemporaryDirectory()]) {
      dirs[d.absolute.path] = d.absolute;
    }
    return _scratch = dirs.values.toList();
  }

  /// The document scanner's output, written loose into Documents on iOS:
  /// `20261110-073532-0.png`.
  static final _scannerOutput = RegExp(r'^\d{8}-\d{6}-\d+\.(png|jpe?g)$');

  /// Names this app or its plugins give scratch files inside the shared
  /// temporary/cache directory. Patterns rather than "everything old": on
  /// Android that directory is also the cache that holds the OMR models, the
  /// soundfont and the engrave cache.
  static final _scratchName = RegExp(
      r'^(omr_page_|scan_\d|decode_\d|image_cropper_|image_picker|scaled_)');

  /// Deletes [path] if it is a scratch copy: inside a scratch directory, or a
  /// document-scanner output loose in Documents. Anything else — a file the
  /// picker handed over in place, the user's own document — is left alone.
  Future<void> deleteScratch(String? path) async {
    if (path == null || path.isEmpty || path.startsWith('content://')) return;
    final file = File(path).absolute;
    if (!await _isScratch(file)) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[cleanup] could not delete $path: $e');
    }
  }

  Future<bool> _isScratch(File file) async {
    final path = file.path;
    for (final dir in await _scratchDirs()) {
      if (path.startsWith('${dir.path}/')) return true;
    }
    final docs = (await _docs()).absolute.path;
    return file.parent.path == docs &&
        _scannerOutput.hasMatch(file.uri.pathSegments.last);
  }

  /// At [launchSweepDelay] after launch: [sweep], then compress any scan
  /// sources still stored as PNG.
  void scheduleLaunchSweep() {
    Timer(launchSweepDelay, () async {
      try {
        await sweep();
        await ScanSourceStore().compressAll();
      } catch (e) {
        debugPrint('[cleanup] launch sweep failed: $e');
      }
    });
  }

  /// Deletes leftovers older than [minimumAge]. Returns the bytes freed.
  Future<int> sweep() async {
    var freed = 0;
    Future<void> remove(File f, String why) async {
      try {
        final size = await f.length();
        await f.delete();
        freed += size;
        debugPrint('[cleanup] removed ${f.path.split('/').last} ($why, '
            '${(size / 1e6).toStringAsFixed(1)} MB)');
      } catch (_) {}
    }

    final cutoff = _now().subtract(minimumAge);
    Future<bool> old(File f) async {
      try {
        return (await f.lastModified()).isBefore(cutoff);
      } catch (_) {
        return false;
      }
    }

    // 1. Plugin scratch. iOS's tmp/ is scratch by definition, so every old
    //    file in it goes (picked files land there under their own names, with
    //    no pattern to match); in the shared cache directory only known
    //    scratch names do.
    final scratch = await _scratchDirs();
    final cacheDir = (await getTemporaryDirectory()).absolute.path;
    for (final dir in scratch) {
      final wholeDirIsScratch = dir.path != cacheDir;
      try {
        if (!await dir.exists()) continue;
        // Recursive in the cache directory too, but only for the picker's
        // own subfolder: the rest of it is the caches named above.
        await for (final e in dir.list(recursive: true)) {
          if (e is! File) continue;
          final name = e.uri.pathSegments.last;
          final topLevel = e.parent.absolute.path == dir.path;
          final inPickerFolder = e.path.contains('/file_picker/');
          final isScratch = wholeDirIsScratch ||
              inPickerFolder ||
              (topLevel && _scratchName.hasMatch(name));
          if (isScratch && await old(e)) await remove(e, 'scratch');
        }
      } catch (e) {
        debugPrint('[cleanup] could not sweep ${dir.path}: $e');
      }
    }

    // 2. Document-scanner output loose in Documents.
    final docs = await _docs();
    if (await docs.exists()) {
      await for (final e in docs.list()) {
        if (e is File &&
            _scannerOutput.hasMatch(e.uri.pathSegments.last) &&
            await old(e)) {
          await remove(e, 'scanner output');
        }
      }
    }

    // 3. Media files no stored state names.
    await _sweepUnreferencedMedia(docs, old, remove);
    if (freed > 0) {
      debugPrint('[cleanup] freed ${(freed / 1e6).toStringAsFixed(1)} MB');
    }
    return freed;
  }

  /// The folders whose files belong to a medium.
  static const _mediaFolders = ['media', 'teacher_recordings'];

  /// Deletes files under [_mediaFolders] whose documents-relative path appears
  /// in no stored preference at all.
  ///
  /// "Appears anywhere" rather than "is named by a media row", deliberately:
  /// it also protects a legacy `teacherRecording.*` recording not yet migrated
  /// (stored as an ABSOLUTE path, which contains the relative one), a shrunk
  /// video waiting for its swap, and whatever a future store adds. The cost is
  /// only that an odd reference keeps a file alive.
  ///
  /// Refuses to run when there are no media rows at all: that is what a
  /// device whose preferences were lost but whose Documents survived looks
  /// like, and there every file would read as unreferenced.
  Future<void> _sweepUnreferencedMedia(
    Directory docs,
    Future<bool> Function(File) old,
    Future<void> Function(File, String) remove,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    if (!keys.any((k) => k.startsWith('pieceMedia.'))) return;
    final everything = StringBuffer();
    for (final key in keys) {
      final value = prefs.get(key);
      if (value is String) {
        everything.writeln(value);
      } else if (value is List) {
        everything.writeln(value.join('\n'));
      }
    }
    final referenced = everything.toString();

    final root = docs.absolute.path;
    for (final folder in _mediaFolders) {
      final dir = Directory('$root/$folder');
      if (!await dir.exists()) continue;
      await for (final e in dir.list(recursive: true)) {
        if (e is! File) continue;
        final relative = e.absolute.path.substring(root.length + 1);
        if (e.uri.pathSegments.last.startsWith('.')) continue;
        if (referenced.contains(relative)) continue;
        if (!await old(e)) continue;
        await remove(e, 'no medium refers to it');
      }
    }
  }
}

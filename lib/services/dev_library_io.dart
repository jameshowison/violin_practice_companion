import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'piece_storage_io.dart';

/// Where `scripts/push_dev_library.sh` stages a library, under Documents.
const String devLibraryFolder = 'dev_library';

/// The Documents folders a dev library mirrors, ids and layout as-is.
const List<String> devLibrarySyncedFolders = [
  'scanned_pieces',
  'editable_fixtures',
  'section_overrides',
  'media',
  'teacher_recordings',
  'scan_sources',
];

/// The push half of the dev-library sync: merges a library staged in
/// `Documents/dev_library/` into this device's own Documents and prefs.
///
/// The library is a private sibling repo kept OUTSIDE the app and copied on
/// over the cable (`scripts/sync_dev_library.sh`), so a release build ships
/// none of it and a store install never has a `state.json` to find — that
/// absence is the whole gate. Not `kDebugMode`: physical-device installs are
/// release builds, and that is where the library is wanted most.
///
/// Everything is a three-way merge per item — a file, a media row, a title, or
/// the library blob — between the library (L), this device (D) and the
/// fingerprints recorded at this device's last sync (the base, B):
///
///   L == D          in sync
///   D == B, L != B  the library moved on: apply L (write or delete)
///   L == B, D != B  this device moved on: keep D for the next pull
///   all differ      conflict: keep D, warn, and leave B so the pull sees it
///
/// The pull half is `scripts/pull_dev_library.sh`, which applies the same
/// table the other way. The two must fingerprint identically — see [fnv1a]
/// and [canonicalJson], mirrored in that script.
class DevLibraryIngester {
  DevLibraryIngester({Directory? root}) : _root = root;

  Directory? _root;

  static const _baseKey = 'devLibrary.base';
  static const _libraryKey = 'pieceLibrary'; // PieceLibraryStore's key
  static const _mediaPrefix = 'pieceMedia.'; // PieceMediaStore's key prefix

  /// Null when no library has been staged — the normal case, and the only one
  /// a released app will ever see.
  Future<DevLibraryReport?> ingest() async {
    final docs = _root ??= await getApplicationDocumentsDirectory();
    final stage = Directory('${docs.path}/$devLibraryFolder');
    final stateFile = File('${stage.path}/state.json');
    if (!await stateFile.exists()) return null;

    final storage = PieceStorage(root: docs);
    // Normalise the title cache first, so this side reads the same index the
    // pull script will.
    await storage.loadScannedPieces();

    final prefs = await SharedPreferences.getInstance();
    final state =
        jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
    final lib = await _snapshot(stage, _stateValues(state));
    final dev = await _snapshot(docs, await _deviceValues(docs, prefs));
    final base = _decodeBase(prefs.getString(_baseKey));

    final report = DevLibraryReport();
    final nextBase = <String, String>{};
    final apply = <String>[];

    for (final key in {...lib.fps.keys, ...dev.fps.keys, ...base.keys}) {
      final l = lib.fps[key], d = dev.fps[key];
      var b = base[key];
      // A fresh device's library blob is just the first-launch seed: when the
      // library HAS one, take it rather than calling it a conflict. Only then —
      // with no library blob, the device's is the only copy there is.
      if (key == _libraryKey && b == null && l != null) b = d;
      if (l == d) {
        if (l != null) nextBase[key] = l;
      } else if (d == b) {
        apply.add(key);
        if (l != null) nextBase[key] = l;
      } else {
        if (l == b) {
          report.kept++;
        } else {
          report.conflicts.add(key);
        }
        if (b != null) nextBase[key] = b;
      }
    }

    await _apply(apply,
        stage: stage, docs: docs, lib: lib, prefs: prefs, storage: storage,
        report: report);
    await prefs.setString(_baseKey, jsonEncode(nextBase));
    debugPrint('[dev_library] $report');
    return report;
  }

  Future<void> _apply(
    List<String> keys, {
    required Directory stage,
    required Directory docs,
    required _Snapshot lib,
    required SharedPreferences prefs,
    required PieceStorage storage,
    required DevLibraryReport report,
  }) async {
    final titles = <String, String?>{};
    // pieceId -> mediaId -> the library's row, or null to drop it.
    final rows = <String, Map<String, Object?>>{};

    for (final key in keys) {
      final present = lib.fps.containsKey(key);
      final value = lib.values[key];
      present ? report.written++ : report.deleted++;
      if (key.startsWith('file:')) {
        final rel = key.substring(5);
        final target = File('${docs.path}/$rel');
        if (present) {
          await target.parent.create(recursive: true);
          await File('${stage.path}/$rel').copy(target.path);
        } else if (await target.exists()) {
          await target.delete();
        }
      } else if (key.startsWith('title:')) {
        titles[key.substring(6)] = present ? value as String : null;
      } else if (key.startsWith('media:')) {
        final [pieceId, mediaId] = key.substring(6).split('/');
        (rows[pieceId] ??= {})[mediaId] = present ? value : null;
      } else if (key == _libraryKey) {
        present
            ? await prefs.setString(_libraryKey, jsonEncode(value))
            : await prefs.remove(_libraryKey);
      }
    }

    for (final MapEntry(key: pieceId, value: changes) in rows.entries) {
      final prefKey = '$_mediaPrefix$pieceId';
      final current = _decodeList(prefs.getString(prefKey));
      final next = <Object?>[
        // Keep this device's order, replacing or dropping changed rows...
        for (final row in current)
          if (!changes.containsKey(_idOf(row)))
            row
          else if (changes[_idOf(row)] != null)
            changes[_idOf(row)],
        // ...then append the library's new rows in the library's order.
        for (final MapEntry(:key, :value) in changes.entries)
          if (value != null && !current.any((r) => _idOf(r) == key)) value,
      ];
      next.isEmpty
          ? await prefs.remove(prefKey)
          : await prefs.setString(prefKey, jsonEncode(next));
    }

    if (titles.isNotEmpty) {
      await _writeTitles(docs, titles);
      await storage.loadScannedPieces(); // drops rows whose file is gone
    }
  }

  // ── Snapshots ─────────────────────────────────────────────────────────────

  /// Fingerprints of every synced file under [root], plus the prefs-held
  /// [values] (already keyed `title:` / `media:` / `pieceLibrary`).
  Future<_Snapshot> _snapshot(
      Directory root, Map<String, Object?> values) async {
    final fps = <String, String>{};
    for (final folder in devLibrarySyncedFolders) {
      final dir = Directory('${root.path}/$folder');
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        final rel = entity.path.substring(root.path.length + 1);
        if (_ignored(rel)) continue;
        fps['file:$rel'] = await fileFingerprint(rel, entity);
      }
    }
    for (final MapEntry(:key, :value) in values.entries) {
      fps[key] = 'j${fnv1a(utf8.encode(canonicalJson(value)))}';
    }
    return _Snapshot(fps, values);
  }

  static bool _ignored(String rel) =>
      rel == 'scanned_pieces/index.json' ||
      rel.split('/').last.startsWith('.');

  /// Library side: `state.json` is `{titles, pieceMedia, pieceLibrary}`.
  static Map<String, Object?> _stateValues(Map<String, dynamic> state) => {
        for (final MapEntry(:key, :value)
            in ((state['titles'] as Map?) ?? {}).entries)
          'title:$key': value,
        for (final MapEntry(key: pieceId, value: list)
            in ((state['pieceMedia'] as Map?) ?? {}).entries)
          for (final row in list as List) 'media:$pieceId/${_idOf(row)}': row,
        if (state['pieceLibrary'] != null) _libraryKey: state['pieceLibrary'],
      };

  /// Device side: the same three things, read from where the app keeps them.
  static Future<Map<String, Object?>> _deviceValues(
      Directory docs, SharedPreferences prefs) async {
    final values = <String, Object?>{};
    for (final MapEntry(:key, :value) in (await _readTitles(docs)).entries) {
      if (value.isNotEmpty) values['title:$key'] = value;
    }
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_mediaPrefix)) continue;
      final pieceId = key.substring(_mediaPrefix.length);
      for (final row in _decodeList(prefs.getString(key))) {
        values['media:$pieceId/${_idOf(row)}'] = row;
      }
    }
    final library = prefs.getString(_libraryKey);
    if (library != null) {
      try {
        values[_libraryKey] = jsonDecode(library);
      } catch (_) {}
    }
    return values;
  }

  // ── scanned_pieces/index.json ─────────────────────────────────────────────

  static Future<Map<String, String>> _readTitles(Directory docs) async {
    final file = File('${docs.path}/scanned_pieces/index.json');
    if (!await file.exists()) return {};
    try {
      final rows =
          (jsonDecode(await file.readAsString()) as Map)['pieces'] as List;
      return {
        for (final r in rows)
          (r as Map)['id'] as String: (r['title'] as String?) ?? '',
      };
    } catch (_) {
      return {};
    }
  }

  /// Sets (or, for null, drops) titles in the index, keeping its order and
  /// appending new ids. [PieceStorage.loadScannedPieces] then reconciles it
  /// with the files actually present.
  static Future<void> _writeTitles(
      Directory docs, Map<String, String?> changes) async {
    final current = await _readTitles(docs);
    final rows = <Map<String, String>>[
      for (final MapEntry(key: id, value: title) in current.entries)
        if (!changes.containsKey(id))
          {'id': id, 'title': title}
        else if (changes[id] != null)
          {'id': id, 'title': changes[id]!},
      for (final MapEntry(key: id, value: title) in changes.entries)
        if (title != null && !current.containsKey(id))
          {'id': id, 'title': title},
    ];
    final file = File('${docs.path}/scanned_pieces/index.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'version': 2, 'pieces': rows}));
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _idOf(Object? row) => (row as Map)['id'] as String;

  static List<Object?> _decodeList(String? raw) {
    if (raw == null) return const [];
    try {
      return [
        for (final r in jsonDecode(raw) as List)
          if (r is Map && r['id'] is String) r,
      ];
    } catch (_) {
      return const [];
    }
  }

  static Map<String, String> _decodeBase(String? raw) {
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }
}

class _Snapshot {
  _Snapshot(this.fps, this.values);
  final Map<String, String> fps;
  final Map<String, Object?> values;
}

/// Media and scan images are compared by size — hashing tens of MB on every
/// launch buys nothing a re-recording or re-scan wouldn't also change.
/// Everything else (scores, sections) is small and hashed.
Future<String> fileFingerprint(String rel, File file) async =>
    rel.startsWith('media/') ||
            rel.startsWith('teacher_recordings/') ||
            rel.startsWith('scan_sources/')
        ? 's${await file.length()}'
        : 'h${fnv1a(await file.readAsBytes())}';

/// 32-bit FNV-1a, as lowercase hex. Stable across runs and languages, unlike
/// `String.hashCode`; `scripts/pull_dev_library.sh` implements the same.
String fnv1a(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16);
}

/// JSON with object keys sorted and no whitespace — what Python's
/// `json.dumps(v, sort_keys=True, separators=(',', ':'), ensure_ascii=False)`
/// produces, so both sides fingerprint a decoded value identically.
String canonicalJson(Object? v) {
  if (v is Map) {
    final keys = [for (final k in v.keys) k as String]..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalJson(v[k])}').join(',')}}';
  }
  if (v is List) return '[${v.map(canonicalJson).join(',')}]';
  return jsonEncode(v);
}

/// What one ingest did, printed as a single `[dev_library]` log line so a sync
/// can be confirmed from the log without looking at the screen.
class DevLibraryReport {
  int written = 0, deleted = 0, kept = 0;
  final List<String> conflicts = [];

  @override
  String toString() => '$written written, $deleted deleted, '
      '$kept local changes awaiting pull'
      '${conflicts.isEmpty ? '' : '; CONFLICTS (kept this device\'s): ${conflicts.join(', ')}'}';
}

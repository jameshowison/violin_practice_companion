import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// The web half of the dev library: merges a bundle made by
/// `scripts/push_dev_library_web.sh` into the browser's prefs.
///
/// The bundle is `{"version": 1, "prefs": {<key>: <string>}}`, its keys already
/// in `piece_storage_web.dart`'s scheme (`piece.<id>.xml`, `piece.<id>.title`,
/// `fixture.<id>.xml`, `sections.<id>`) plus `pieceLibrary`. Media rows are
/// left out: the web build has no file-backed media to point them at.
///
/// Same three-way table as `DevLibraryIngester` on io, per key, against the
/// bundle as this browser last took it (`devLibrary.base`). It is one-way —
/// nothing pulls a browser's edits back into the library — so a key changed
/// here is simply kept, and stops tracking the library until reset.
///
/// Pure Dart (no `package:web`) so the VM tests can drive it; the fetch lives
/// in `dev_library_web.dart`.
class DevLibraryBundleMerger {
  DevLibraryBundleMerger(this.prefs);

  final SharedPreferences prefs;

  static const _baseKey = 'devLibrary.base';
  static const _libraryKey = 'pieceLibrary';

  Future<String> merge(Map<String, dynamic> bundle) async {
    final lib = ((bundle['prefs'] as Map?) ?? {}).cast<String, String>();
    final base = _decodeBase(prefs.getString(_baseKey));
    final nextBase = <String, String>{};
    var written = 0, deleted = 0, kept = 0;
    final conflicts = <String>[];

    for (final key in {...lib.keys, ...base.keys}) {
      final l = _fp(key, lib[key]), d = _fp(key, prefs.getString(key));
      var b = base[key];
      // A fresh browser's library blob is only the first-launch seed.
      if (key == _libraryKey && b == null && l != null) b = d;
      if (l == d) {
        if (l != null) nextBase[key] = l;
      } else if (d == b) {
        if (l != null) {
          await prefs.setString(key, lib[key]!);
          nextBase[key] = l;
          written++;
        } else {
          await prefs.remove(key);
          deleted++;
        }
      } else {
        l == b ? kept++ : conflicts.add(key);
        if (b != null) nextBase[key] = b;
      }
    }

    await prefs.setString(_baseKey, jsonEncode(nextBase));
    final report = '$written written, $deleted deleted, $kept local changes kept'
        '${conflicts.isEmpty ? '' : '; CONFLICTS (kept this browser\'s): ${conflicts.join(', ')}'}';
    debugPrint('[dev_library] $report');
    return report;
  }

  /// JSON values are compared canonically, so the app re-encoding a blob it
  /// read doesn't count as a local change; scores and titles byte for byte.
  static String? _fp(String key, String? value) {
    if (value == null) return null;
    var text = value;
    if (key == _libraryKey || key.startsWith('sections.')) {
      try {
        text = _canonicalJson(jsonDecode(value));
      } catch (_) {}
    }
    return _fnv1a(utf8.encode(text));
  }

  static String _fnv1a(List<int> bytes) {
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  static String _canonicalJson(Object? v) {
    if (v is Map) {
      final keys = [for (final k in v.keys) k as String]..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalJson(v[k])}').join(',')}}';
    }
    if (v is List) return '[${v.map(_canonicalJson).join(',')}]';
    return jsonEncode(v);
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

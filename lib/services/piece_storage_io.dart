import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/piece.dart';
import 'musicxml_parser.dart';
import 'piece_storage_base.dart';

/// Whether this platform can write MusicXML files (and therefore supports
/// editing). True on mobile/desktop. Read via the conditional-import seam so
/// shared code needn't branch on `kIsWeb`.
const bool storageSupportsEditing = true;

/// Mobile/desktop persistence for pieces, under the app documents directory:
///
/// * `scanned_pieces/<id>.musicxml` — imported and scanned scores
/// * `scanned_pieces/index.json` — a **title cache** (see below)
/// * `editable_fixtures/<id>.musicxml` — writable copy of an edited bundled fixture
/// * `section_overrides/<id>.sections.json` — edited section markers
///
/// ## Why the directory, not the index, is the source of truth
///
/// This store used to record each piece's **absolute** path in `index.json`. iOS
/// assigns a new data-container UUID on every reinstall (and on restore from
/// backup), so every recorded path died the moment the app was reinstalled: the
/// list still rendered every title, and every piece failed to open. The files had
/// been preserved all along — only the paths were wrong.
///
/// So [loadScannedPieces] now enumerates the directory and treats `index.json`
/// purely as a cache of titles, repairing it in place when the two disagree. A
/// piece's id is its filename, and its path is recomputed on every load. That
/// makes the whole class of bug unreachable, and matches what
/// [fixtureFilePathIfExists] and [loadSectionsOverride] always did correctly.
///
/// It also fixes two latent problems: the index was append-only with no delete
/// path anywhere in the app, so orphan rows accumulated; and a corrupt index used
/// to lose the entire library.
class PieceStorage {
  /// [root] overrides the documents directory. Production leaves it null and
  /// resolves `getApplicationDocumentsDirectory()` lazily; tests pass a temp dir,
  /// which is what makes this layer testable without a platform channel.
  // An initializing formal would have to name the parameter `_root`, and named
  // parameters can't be private — so the assignment stays explicit.
  // ignore: prefer_initializing_formals
  PieceStorage({Directory? root}) : _root = root;

  Directory? _root;

  static const _ext = '.musicxml';
  static const _indexVersion = 2;

  Future<Directory> _docs() async =>
      _root ??= await getApplicationDocumentsDirectory();

  Future<Directory> _subdir(String name) async {
    final dir = Directory('${(await _docs()).path}/$name');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _scannedPiecesDir() => _subdir('scanned_pieces');
  Future<Directory> _editableFixturesDir() => _subdir('editable_fixtures');
  Future<Directory> _sectionOverridesDir() => _subdir('section_overrides');

  // ── Scanned / imported pieces ───────────────────────────────────────────

  /// Every stored piece, oldest first, with paths freshly computed.
  ///
  /// Reads the directory; consults `index.json` only for titles. A file with no
  /// indexed title recovers it from the score's own `<work-title>`
  /// ([MusicXmlParser.titleOf]), else falls back to the id. Rewrites the index
  /// whenever it no longer matches what's on disk.
  Future<List<Piece>> loadScannedPieces() async {
    final dir = await _scannedPiecesDir();
    final files = <File>[
      for (final entity in await dir.list().toList())
        if (entity is File && entity.path.endsWith(_ext)) entity,
    ];
    if (files.isEmpty) {
      await _writeIndexIfChanged(const []);
      return const [];
    }

    final byId = {for (final f in files) _idOf(f.path): f};
    final titles = await _readIndexTitles();

    // Keep the index's order for ids still present (it is insertion order, so the
    // list doesn't reshuffle under the user), then append anything unindexed.
    final ordered = <String>[
      ...titles.keys.where(byId.containsKey),
      ...(byId.keys.where((id) => !titles.containsKey(id)).toList()
        ..sort(compareByCreatedAt)),
    ];

    final pieces = <Piece>[];
    for (final id in ordered) {
      final file = byId[id]!;
      var title = titles[id];
      if (title == null || title.isEmpty) {
        title = MusicXmlParser.titleOf(await file.readAsString()) ?? id;
      }
      pieces.add(Piece(
        id: id,
        title: title,
        musicXmlFilePath: file.path,
        sections: const [],
      ));
    }
    await _writeIndexIfChanged(pieces);
    return pieces;
  }

  Future<Piece> saveScannedPiece(String title, String musicXml) async {
    final dir = await _scannedPiecesDir();
    final id = scannedPieceId(title,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch);
    final file = File('${dir.path}/$id$_ext');
    await file.writeAsString(musicXml);

    final piece = Piece(
      id: id,
      title: title,
      musicXmlFilePath: file.path,
      sections: const [],
    );
    // Refresh the whole cache from disk rather than appending, so the index can
    // never drift from the directory.
    await loadScannedPieces();
    return piece;
  }

  /// Reads a piece by the handle carried on [Piece.musicXmlFilePath].
  ///
  /// Falls back to matching by filename inside the store when the handle itself
  /// doesn't resolve — a stale absolute path held in memory (or handed over from
  /// an older install) then still finds its file, since the container moves but
  /// the filename doesn't.
  Future<String> readScannedMusicXml(String handle) async {
    final direct = File(handle);
    if (await direct.exists()) return direct.readAsString();

    final name = _basename(handle);
    for (final dir in [
      await _scannedPiecesDir(),
      await _editableFixturesDir(),
    ]) {
      final candidate = File('${dir.path}/$name');
      if (await candidate.exists()) return candidate.readAsString();
    }
    throw FileSystemException('Piece file not found', handle);
  }

  /// Overwrites a piece's MusicXML in place (e.g. after a note-editing
  /// correction). The index is untouched — only the file contents differ.
  Future<void> updateScannedPieceFile(String handle, String newMusicXml) async {
    final direct = File(handle);
    if (await direct.exists()) {
      await direct.writeAsString(newMusicXml);
      return;
    }
    final name = _basename(handle);
    for (final dir in [
      await _scannedPiecesDir(),
      await _editableFixturesDir(),
    ]) {
      final candidate = File('${dir.path}/$name');
      if (await candidate.exists()) {
        await candidate.writeAsString(newMusicXml);
        return;
      }
    }
    throw FileSystemException('Piece file not found', handle);
  }

  // ── Index (a rebuildable title cache) ───────────────────────────────────

  Future<File> _indexFile() async =>
      File('${(await _scannedPiecesDir()).path}/index.json');

  /// `{id: title}` in file order. Tolerant of both schemas and of corruption:
  /// anything unreadable yields an empty map, and the titles are then recovered
  /// from the scores themselves.
  ///
  /// v2 is `{"version": 2, "pieces": [{id, title}]}`. v1 was a bare JSON array
  /// whose rows also carried a `musicXmlFilePath`; that field is deliberately
  /// ignored — it is the stale value this design exists to stop trusting.
  Future<Map<String, String>> _readIndexTitles() async {
    final file = await _indexFile();
    if (!await file.exists()) return {};
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = json.decode(raw);
      final rows = switch (decoded) {
        List<dynamic> legacy => legacy, // v1
        Map<String, dynamic> m => (m['pieces'] as List?) ?? const [],
        _ => const [],
      };
      return {
        for (final row in rows)
          if (row is Map && row['id'] is String)
            row['id'] as String: (row['title'] as String?) ?? '',
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeIndexIfChanged(List<Piece> pieces) async {
    final content = const JsonEncoder.withIndent('  ').convert({
      'version': _indexVersion,
      'pieces': [
        for (final p in pieces) {'id': p.id, 'title': p.title},
      ],
    });
    final file = await _indexFile();
    if (await file.exists() && await file.readAsString() == content) return;
    if (pieces.isEmpty && !await file.exists()) return;
    await file.writeAsString(content);
  }

  // ── Editable fixtures ───────────────────────────────────────────────────

  /// Path to the materialized copy of fixture [id], or null if it hasn't been
  /// edited yet (still asset-backed). Always recomputed — never stored.
  Future<String?> fixtureFilePathIfExists(String id) async {
    final file = File('${(await _editableFixturesDir()).path}/$id$_ext');
    return await file.exists() ? file.path : null;
  }

  Future<String> writeFixtureFile(String id, String xml) async {
    final file = File('${(await _editableFixturesDir()).path}/$id$_ext');
    await file.writeAsString(xml);
    return file.path;
  }

  // ── Section overrides ───────────────────────────────────────────────────

  /// The raw `sections` list from piece [id]'s override sidecar, or null if the
  /// piece has never had its sections edited.
  Future<List<Map<String, dynamic>>?> loadSectionsOverride(String id) async {
    final file =
        File('${(await _sectionOverridesDir()).path}/$id.sections.json');
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      if (raw.isEmpty) return null;
      final j = json.decode(raw) as Map<String, dynamic>;
      return (j['sections'] as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSectionsOverride(
      String id, List<Map<String, dynamic>> sections) async {
    final file =
        File('${(await _sectionOverridesDir()).path}/$id.sections.json');
    await file.writeAsString(json.encode({'sections': sections}));
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static String _idOf(String path) {
    final name = _basename(path);
    return name.endsWith(_ext) ? name.substring(0, name.length - _ext.length) : name;
  }

  /// Last path segment, tolerating either separator so a handle written on one
  /// platform is still readable on another.
  static String _basename(String path) {
    final cut = path.lastIndexOf(RegExp(r'[/\\]'));
    return cut < 0 ? path : path.substring(cut + 1);
  }
}

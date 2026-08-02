import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/piece.dart';
import 'musicxml_parser.dart';
import 'piece_storage_base.dart';

/// Web supports editing: unlike the earlier stub, this backend can write.
///
/// Note this also enables the measure editor on web (it is gated on
/// `PieceRepository.supportsEditing`), which follows from having a real store.
const bool storageSupportsEditing = true;

/// Web persistence for pieces, on `shared_preferences` (localStorage-backed).
///
/// Chosen over hand-written IndexedDB interop because it needs no new dependency
/// and no JS interop, and — being plain Dart with no `dart:html` — this class is
/// directly importable by the existing VM unit tests via
/// `SharedPreferences.setMockInitialValues`.
///
/// ## Keys
///
/// | Key | Holds |
/// |---|---|
/// | `piece.<id>.xml` | the MusicXML of an imported/scanned score |
/// | `piece.<id>.title` | its title |
/// | `fixture.<id>.xml` | writable copy of an edited bundled fixture |
/// | `sections.<id>` | edited section markers, as the sidecar JSON |
///
/// The **key set is the index** — there is no separate index record to go stale,
/// which is the web-side equivalent of the io backend treating its directory as
/// the source of truth. A piece whose `.title` key is missing recovers its name
/// from the score's own `<work-title>`.
///
/// ## Capacity
///
/// localStorage is roughly 5 MB per origin. Scores here run 12–33 KB, so that is
/// on the order of 150–400 songs. IndexedDB is the upgrade path if images or PDFs
/// are ever stored alongside.
class PieceStorage {
  PieceStorage();

  static const _piecePrefix = 'piece.';
  static const _fixturePrefix = 'fixture.';
  static const _sectionsPrefix = 'sections.';
  static const _xmlSuffix = '.xml';
  static const _titleSuffix = '.title';

  /// Handle scheme for [Piece.musicXmlFilePath]. That field is an opaque storage
  /// handle, not necessarily a filesystem path — on web there is no filesystem,
  /// so it names a key instead. Keeping the shared [Piece] model unchanged is
  /// deliberate.
  static const _scheme = 'prefs:';
  static const _pieceKind = 'piece';
  static const _fixtureKind = 'fixture';

  static String _handle(String kind, String id) => '$_scheme$kind:$id';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _open() async =>
      _prefs ??= await SharedPreferences.getInstance();

  // ── Scanned / imported pieces ───────────────────────────────────────────

  /// Every stored piece, oldest first by the timestamp in its id (web storage has
  /// no insertion order of its own — see [compareByCreatedAt]).
  Future<List<Piece>> loadScannedPieces() async {
    final prefs = await _open();
    final ids = <String>[
      for (final key in prefs.getKeys())
        if (key.startsWith(_piecePrefix) && key.endsWith(_xmlSuffix))
          key.substring(_piecePrefix.length, key.length - _xmlSuffix.length),
    ]..sort(compareByCreatedAt);

    return [
      for (final id in ids)
        Piece(
          id: id,
          title: _titleFor(prefs, id),
          musicXmlFilePath: _handle(_pieceKind, id),
          sections: const [],
        ),
    ];
  }

  String _titleFor(SharedPreferences prefs, String id) {
    final stored = prefs.getString('$_piecePrefix$id$_titleSuffix');
    if (stored != null && stored.isNotEmpty) return stored;
    final xml = prefs.getString('$_piecePrefix$id$_xmlSuffix');
    return (xml == null ? null : MusicXmlParser.titleOf(xml)) ?? id;
  }

  Future<Piece> saveScannedPiece(String title, String musicXml) async {
    final prefs = await _open();
    final id = scannedPieceId(title,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch);
    await prefs.setString('$_piecePrefix$id$_xmlSuffix', musicXml);
    await prefs.setString('$_piecePrefix$id$_titleSuffix', title);
    return Piece(
      id: id,
      title: title,
      musicXmlFilePath: _handle(_pieceKind, id),
      sections: const [],
    );
  }

  Future<String> readScannedMusicXml(String handle) async {
    final prefs = await _open();
    final key = _keyForHandle(handle);
    final xml = prefs.getString(key);
    if (xml == null) throw StateError('No stored piece for handle "$handle"');
    return xml;
  }

  Future<void> updateScannedPieceFile(String handle, String newMusicXml) async {
    final prefs = await _open();
    await prefs.setString(_keyForHandle(handle), newMusicXml);
  }

  /// Removes piece [id]. The key set IS the index here, so dropping the `.xml`
  /// key delists it; the `.title` key goes with it so no orphan keys are left
  /// behind. Idempotent — removing an absent key is a no-op.
  Future<void> deleteScannedPiece(String id) async {
    final prefs = await _open();
    await prefs.remove('$_piecePrefix$id$_xmlSuffix');
    await prefs.remove('$_piecePrefix$id$_titleSuffix');
  }

  /// Storage key behind a `prefs:<kind>:<id>` handle.
  static String _keyForHandle(String handle) {
    if (!handle.startsWith(_scheme)) {
      throw ArgumentError.value(handle, 'handle', 'Not a web storage handle');
    }
    final rest = handle.substring(_scheme.length);
    final colon = rest.indexOf(':');
    if (colon < 0) {
      throw ArgumentError.value(handle, 'handle', 'Malformed storage handle');
    }
    final kind = rest.substring(0, colon);
    final id = rest.substring(colon + 1);
    return switch (kind) {
      _pieceKind => '$_piecePrefix$id$_xmlSuffix',
      _fixtureKind => '$_fixturePrefix$id$_xmlSuffix',
      _ => throw ArgumentError.value(handle, 'handle', 'Unknown handle kind'),
    };
  }

  // ── Editable fixtures ───────────────────────────────────────────────────

  Future<String?> fixtureFilePathIfExists(String id) async {
    final prefs = await _open();
    return prefs.containsKey('$_fixturePrefix$id$_xmlSuffix')
        ? _handle(_fixtureKind, id)
        : null;
  }

  Future<String> writeFixtureFile(String id, String xml) async {
    final prefs = await _open();
    await prefs.setString('$_fixturePrefix$id$_xmlSuffix', xml);
    return _handle(_fixtureKind, id);
  }

  /// Discards the writable copy of fixture [id], so it goes back to tracking the
  /// bundled asset. A different keyspace from `piece.<id>.xml`, so this never
  /// touches a scan that happens to share the id. Idempotent.
  Future<void> deleteFixtureFile(String id) async {
    final prefs = await _open();
    await prefs.remove('$_fixturePrefix$id$_xmlSuffix');
  }

  // ── Section overrides ───────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>?> loadSectionsOverride(String id) async {
    final prefs = await _open();
    final raw = prefs.getString('$_sectionsPrefix$id');
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = json.decode(raw) as Map<String, dynamic>;
      return (j['sections'] as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSectionsOverride(
      String id, List<Map<String, dynamic>> sections) async {
    final prefs = await _open();
    await prefs.setString(
        '$_sectionsPrefix$id', json.encode({'sections': sections}));
  }

  /// Discards piece [id]'s section overrides. Idempotent.
  Future<void> deleteSectionsOverride(String id) async {
    final prefs = await _open();
    await prefs.remove('$_sectionsPrefix$id');
  }
}

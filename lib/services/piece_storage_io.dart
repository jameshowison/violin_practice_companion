import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/piece.dart';

/// Whether this platform can write MusicXML files (and therefore supports
/// editing). True on mobile/desktop; the web stub sets it false. Read via the
/// conditional-import seam so shared code needn't branch on `kIsWeb`.
const bool storageSupportsEditing = true;

/// Mobile/desktop persistence for scanned pieces: each piece's MusicXML is
/// written to `<docs>/scanned_pieces/<id>.musicxml`, and an `index.json` in
/// the same directory tracks `{id, title, musicXmlFilePath}` for [loadScannedPieces].
Future<Directory> _scannedPiecesDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/scanned_pieces');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<File> _indexFile() async {
  final dir = await _scannedPiecesDir();
  return File('${dir.path}/index.json');
}

Future<List<Map<String, dynamic>>> _readIndex(File file) async {
  if (!await file.exists()) return [];
  final raw = await file.readAsString();
  if (raw.isEmpty) return [];
  return (json.decode(raw) as List).cast<Map<String, dynamic>>();
}

Future<List<Piece>> loadScannedPieces() async {
  final entries = await _readIndex(await _indexFile());
  return entries
      .map((e) => Piece(
            id: e['id'] as String,
            title: e['title'] as String,
            musicXmlFilePath: e['musicXmlFilePath'] as String,
            sections: const [],
          ))
      .toList();
}

Future<Piece> saveScannedPiece(String title, String musicXml) async {
  final dir = await _scannedPiecesDir();
  final id = '${_slugify(title)}_${DateTime.now().millisecondsSinceEpoch}';
  final musicXmlFile = File('${dir.path}/$id.musicxml');
  await musicXmlFile.writeAsString(musicXml);

  final indexFile = await _indexFile();
  final entries = await _readIndex(indexFile);
  entries.add({'id': id, 'title': title, 'musicXmlFilePath': musicXmlFile.path});
  await indexFile.writeAsString(json.encode(entries));

  return Piece(
    id: id,
    title: title,
    musicXmlFilePath: musicXmlFile.path,
    sections: const [],
  );
}

Future<String> readScannedMusicXml(String musicXmlFilePath) {
  return File(musicXmlFilePath).readAsString();
}

/// Overwrites an existing scanned piece's MusicXML file in place (e.g. after a
/// note-editing correction). The `index.json` entry is unchanged — only the
/// file contents differ.
Future<void> updateScannedPieceFile(String musicXmlFilePath, String newMusicXml) {
  return File(musicXmlFilePath).writeAsString(newMusicXml);
}

/// Editable fixtures: a bundled fixture becomes editable by materializing a
/// writable copy at `<docs>/editable_fixtures/<id>.musicxml`. Once present, the
/// repository loads the piece from this file instead of the read-only asset, so
/// edits persist across launches.
Future<Directory> _editableFixturesDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/editable_fixtures');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Path to the materialized copy of fixture [id], or null if it hasn't been
/// edited yet (still asset-backed).
Future<String?> fixtureFilePathIfExists(String id) async {
  final docs = await getApplicationDocumentsDirectory();
  final file = File('${docs.path}/editable_fixtures/$id.musicxml');
  return await file.exists() ? file.path : null;
}

/// Writes [xml] to fixture [id]'s editable file (creating it on first edit) and
/// returns the path.
Future<String> writeFixtureFile(String id, String xml) async {
  final dir = await _editableFixturesDir();
  final file = File('${dir.path}/$id.musicxml');
  await file.writeAsString(xml);
  return file.path;
}

String _slugify(String title) {
  final slug = title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'untitled' : slug;
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/piece.dart';

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

String _slugify(String title) {
  final slug = title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'untitled' : slug;
}

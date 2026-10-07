import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Keeps the ABC text a piece was imported from, as `abc_sources/<pieceId>.abc`.
///
/// The app stores only the converted MusicXML, so before this anything the
/// converter didn't carry across was gone for good — which is how every `w:`
/// lyric imported before lyrics support was lost. With the source kept, a
/// later, better converter can be re-run over it.
///
/// The folder is part of the dev-library sync (`dev_library_io.dart`), like
/// `scan_sources/`.
class AbcSourceStore {
  AbcSourceStore({Directory? root}) : _root = root;

  Directory? _root;

  static const folder = 'abc_sources';

  Future<File> _file(String pieceId) async {
    final docs = _root ??= await getApplicationDocumentsDirectory();
    return File('${docs.path}/$folder/$pieceId.abc');
  }

  Future<void> save(String pieceId, String abc) async {
    final file = await _file(pieceId);
    await file.parent.create(recursive: true);
    await file.writeAsString(abc);
  }

  /// Null for a piece that wasn't imported from ABC (or predates this store).
  Future<String?> read(String pieceId) async {
    final file = await _file(pieceId);
    return await file.exists() ? file.readAsString() : null;
  }

  /// Idempotent: a piece that wasn't imported from ABC has nothing to remove.
  Future<void> delete(String pieceId) async {
    final file = await _file(pieceId);
    if (await file.exists()) await file.delete();
  }
}

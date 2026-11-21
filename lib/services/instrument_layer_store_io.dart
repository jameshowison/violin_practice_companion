import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The instrument layer's stored part (docs/family/layers.md): per piece and
/// per instrument, what a player of that instrument has decided about the
/// piece that the shared score doesn't say. Today, which notes are pinned to
/// the open string (0) or the 4th finger (4).
///
/// One file per piece and instrument, `instrument_layers/<pieceId>.<id>.json`:
/// `{"version": 1, "stringChoices": {"<measure>:<index>": 0|4}}`, where
/// `<measure>` is the source's measure number and `<index>` the note's place
/// in that measure's notes, as `ParsedPiece` counts them. The folder is part of
/// the dev-library sync, and a share carries the piece's files.
class InstrumentLayerStore {
  // ignore: prefer_initializing_formals
  InstrumentLayerStore({Directory? root}) : _root = root;

  Directory? _root;

  static const folder = 'instrument_layers';

  Future<Directory> _dir() async {
    final docs = _root ??= await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$folder');
  }

  Future<File> _file(String pieceId, String instrumentId) async =>
      File('${(await _dir()).path}/$pieceId.$instrumentId.json');

  /// Piece [pieceId]'s string choices for [instrumentId]; empty for none.
  Future<Map<String, int>> stringChoices(
      String pieceId, String instrumentId) async {
    final file = await _file(pieceId, instrumentId);
    if (!await file.exists()) return const {};
    try {
      final j = json.decode(await file.readAsString()) as Map<String, dynamic>;
      return {
        for (final e in (j['stringChoices'] as Map? ?? const {}).entries)
          '${e.key}': (e.value as num).toInt(),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Replaces piece [pieceId]'s string choices for [instrumentId]; an empty
  /// map removes the file.
  Future<void> setStringChoices(
      String pieceId, String instrumentId, Map<String, int> choices) async {
    final file = await _file(pieceId, instrumentId);
    if (choices.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    final sorted = Map.fromEntries(
        choices.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    await file.writeAsString(const JsonEncoder.withIndent('  ')
        .convert({'version': 1, 'stringChoices': sorted}));
  }

  /// [choices] with measure [measureNumber]'s entries replaced by
  /// [forMeasure] (index → finger).
  static Map<String, int> withMeasure(Map<String, int> choices,
          int measureNumber, Map<int, int> forMeasure) =>
      {
        for (final e in choices.entries)
          if (measureOf(e.key) != measureNumber) e.key: e.value,
        for (final e in forMeasure.entries) '$measureNumber:${e.key}': e.value,
      };

  /// The measure number in a `<measure>:<index>` key, or null.
  static int? measureOf(String key) => int.tryParse(key.split(':').first);

  /// After measure [deleted] is removed from piece [pieceId]: its choices go,
  /// and every later measure's move back one, as the score renumbers them.
  Future<void> afterMeasureDelete(String pieceId, int deleted) async {
    for (final id in await instrumentsOf(pieceId)) {
      final choices = await stringChoices(pieceId, id);
      final moved = <String, int>{};
      for (final e in choices.entries) {
        final m = measureOf(e.key);
        if (m == null || m == deleted) continue;
        final index = e.key.substring(e.key.indexOf(':') + 1);
        moved[m > deleted ? '${m - 1}:$index' : e.key] = e.value;
      }
      await setStringChoices(pieceId, id, moved);
    }
  }

  /// The instruments piece [pieceId] has a layer for.
  Future<List<String>> instrumentsOf(String pieceId) async {
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final prefix = '$pieceId.';
    return [
      await for (final f in dir.list())
        if (f is File)
          if (f.uri.pathSegments.last case final name
              when name.startsWith(prefix) && name.endsWith('.json'))
            name.substring(prefix.length, name.length - '.json'.length),
    ];
  }

  /// Removes every layer of piece [pieceId]. Idempotent.
  Future<void> delete(String pieceId) async {
    for (final id in await instrumentsOf(pieceId)) {
      final file = await _file(pieceId, id);
      if (await file.exists()) await file.delete();
    }
  }
}

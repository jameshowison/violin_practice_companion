import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/piece.dart';
import '../models/piece_media.dart';
import '../models/section.dart';
import 'instrument_layer_store.dart';
import 'piece_media_store.dart';
import 'piece_repository.dart';
import 'piece_share_bundle.dart';
import 'piece_storage_base.dart';
import 'piece_storage_io.dart';

/// Sharing a piece needs files on disk on both ends.
const bool pieceShareSupported = true;

const String _alignmentPrefix = 'mediaAlignment.';

/// Writes and reads `.stringlings` files — see `piece_share_bundle.dart` for
/// the format, and for every decision about what goes where. This class only
/// moves bytes.
///
/// [docs] and [temp] override the documents and temporary directories, as
/// [PieceStorage]'s `root` does, so tests run against temp folders.
class PieceShareIo {
  // Initializing formals can't be private named parameters; see PieceStorage.
  // ignore: prefer_initializing_formals
  PieceShareIo({Directory? docs, Directory? temp})
      // ignore: prefer_initializing_formals
      : _docs = docs,
        // ignore: prefer_initializing_formals
        _temp = temp;

  Directory? _docs;
  Directory? _temp;

  Future<Directory> _docsDir() async =>
      _docs ??= await getApplicationDocumentsDirectory();
  Future<Directory> _tempDir() async =>
      _temp ??= await getTemporaryDirectory();

  // ── Export ────────────────────────────────────────────────────────────────

  /// Bytes the chosen media will add to the share, counting a file shared by
  /// two refs once. Missing files count 0 (and are left out of the share).
  Future<int> estimateBytes(List<ShareMediaChoice> choices) async {
    final docs = await _docsDir();
    var total = 0;
    for (final rel in planShareExport(choices).files.values.toSet()) {
      final f = File('${docs.path}/$rel');
      if (await f.exists()) total += await f.length();
    }
    return total;
  }

  /// Builds the share file and returns its path, in a fresh folder under the
  /// temporary directory so the file can carry the piece's title as its name.
  Future<String> export({
    required String pieceId,
    required String title,
    required bool bundled,
    required String musicXml,
    required List<Section> sections,
    required List<ShareMediaChoice> choices,
  }) async {
    final docs = await _docsDir();
    final prefs = await SharedPreferences.getInstance();
    final plan = planShareExport(choices);

    // A file that has gone missing would leave a row pointing at nothing on
    // the receiver; leave that row out instead.
    final missing = <String>{};
    for (final MapEntry(key: bundlePath, value: rel) in plan.files.entries) {
      if (!await File('${docs.path}/$rel').exists()) missing.add(bundlePath);
    }
    final media = [
      for (final m in plan.media)
        if (![m.audio, m.analysis, m.video]
            .any((r) => r != null && missing.contains(r.path)))
          m,
    ];

    final manifest = PieceShareManifest(
      pieceId: pieceId,
      title: title,
      bundled: bundled,
      hasSections: sections.isNotEmpty,
      media: media,
      alignments: {
        for (final m in media)
          m.id: ?prefs.getString('$_alignmentPrefix${m.alignmentKey}'),
      },
      display: {
        for (final name in kSharedDisplayPrefs)
          name: ?prefs.getString('display.$name.$pieceId'),
      },
    );

    final outDir = Directory(
        '${(await _tempDir()).path}/share_out_${DateTime.now().millisecondsSinceEpoch}');
    await outDir.create(recursive: true);
    final outPath = '${outDir.path}/${shareFileNameFor(title)}';

    final encoder = ZipFileEncoder();
    // Stored, not deflated: the bulk is mp4/m4a/mp3, already compressed, and
    // deflating a few hundred MB on the phone buys nothing but a wait.
    encoder.create(outPath, level: ZipFileEncoder.store);
    try {
      encoder.addArchiveFile(ArchiveFile.string(
          kShareManifestName, jsonEncode(manifest.toJson())));
      encoder
          .addArchiveFile(ArchiveFile.string(kShareScoreName, musicXml));
      if (sections.isNotEmpty) {
        encoder.addArchiveFile(ArchiveFile.string(
            kShareSectionsName,
            jsonEncode({
              'sections': [for (final s in sections) s.toJson()],
            })));
      }
      final layers = InstrumentLayerStore(root: docs);
      for (final id in await layers.instrumentsOf(pieceId)) {
        encoder.addArchiveFile(ArchiveFile.string(
            '$kShareLayersDir/$id.json',
            jsonEncode({
              'stringChoices': await layers.stringChoices(pieceId, id),
            })));
      }
      final kept = {
        for (final m in media)
          for (final r in [m.audio, m.analysis, m.video])
            if (r != null) r.path,
      };
      for (final MapEntry(key: bundlePath, value: rel) in plan.files.entries) {
        if (!kept.contains(bundlePath)) continue;
        await encoder.addFile(File('${docs.path}/$rel'), bundlePath);
      }
    } finally {
      await encoder.close();
    }
    debugPrint('[share] wrote $outPath (${media.length} media)');
    return outPath;
  }

  /// Removes share files left from earlier exports. The share sheet gives no
  /// reliable "done with it" signal (AirDrop may still be reading when it
  /// returns), so they are swept on the next export instead.
  Future<void> sweepOldExports() async {
    final temp = await _tempDir();
    if (!await temp.exists()) return;
    await for (final e in temp.list()) {
      if (e is Directory && e.path.split('/').last.startsWith('share_out_')) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  // ── Import ────────────────────────────────────────────────────────────────

  /// Unpacks a share file into a private temp folder and reads its manifest.
  /// Throws [FormatException] for anything that isn't a share this build can
  /// read. The caller must [OpenedShare.dispose] it.
  Future<OpenedShare> open(String path) async {
    final dir = Directory(
        '${(await _tempDir()).path}/share_in_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    try {
      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        // extractArchiveToDisk refuses entries that would land outside dir.
        await extractArchiveToDisk(archive, dir.path);
      } finally {
        await input.close();
      }
      final manifestFile = File('${dir.path}/$kShareManifestName');
      final scoreFile = File('${dir.path}/$kShareScoreName');
      if (!await manifestFile.exists() || !await scoreFile.exists()) {
        throw const FormatException('Not a shared piece');
      }
      final manifest = PieceShareManifest.fromJson(
          jsonDecode(await manifestFile.readAsString()));
      var sections = <Section>[];
      final sectionsFile = File('${dir.path}/$kShareSectionsName');
      if (await sectionsFile.exists()) {
        try {
          final j = jsonDecode(await sectionsFile.readAsString()) as Map;
          sections = [
            for (final s in j['sections'] as List)
              Section.fromJson((s as Map).cast<String, dynamic>()),
          ];
        } catch (_) {}
      }
      final layers = <String, Map<String, int>>{};
      final layersDir = Directory('${dir.path}/$kShareLayersDir');
      if (await layersDir.exists()) {
        await for (final f in layersDir.list()) {
          final name = f.uri.pathSegments.last;
          if (f is! File || !name.endsWith('.json')) continue;
          try {
            final j = jsonDecode(await f.readAsString()) as Map;
            layers[name.substring(0, name.length - '.json'.length)] = {
              for (final e in (j['stringChoices'] as Map).entries)
                '${e.key}': (e.value as num).toInt(),
            };
          } catch (_) {}
        }
      }
      return OpenedShare._(
          manifest, await scoreFile.readAsString(), sections, layers, dir);
    } on FormatException {
      await _deleteQuietly(dir);
      rethrow;
    } catch (e) {
      await _deleteQuietly(dir);
      throw FormatException('Could not read the shared piece ($e)');
    }
  }

  /// Merges [share] into this device, asking [onScoreConflict] when it
  /// already has the piece with a different score. Returns null when the user
  /// cancelled there.
  ///
  /// [pieces] is everything the app currently lists, so "do I have this
  /// piece?" is answered the same way the piece list answers it.
  Future<ShareImportResult?> apply(
    OpenedShare share, {
    required PieceRepository repo,
    required List<Piece> pieces,
    required Future<ShareConflictChoice?> Function(String title)
        onScoreConflict,
    DateTime? now,
  }) async {
    final m = share.manifest;
    final at = now ?? DateTime.now();
    final docs = await _docsDir();
    final storage = PieceStorage(root: docs);
    await repo.catalog();
    final existing = pieces.where((p) => p.id == m.pieceId).firstOrNull;

    String freshPieceId() =>
        scannedPieceId(m.title, createdAtMillis: at.millisecondsSinceEpoch);

    String pieceId;
    ShareScoreAction action;
    if (existing != null) {
      final current = await repo.loadMusicXml(existing);
      if (sameScore(current, share.musicXml)) {
        pieceId = existing.id;
        action = ShareScoreAction.keep;
      } else {
        switch (await onScoreConflict(existing.title)) {
          case null:
            return null;
          case ShareConflictChoice.replace:
            pieceId = existing.id;
            action = ShareScoreAction.replace;
            await repo.writeEditedMusicXml(existing, share.musicXml);
            if (share.sections.isNotEmpty) {
              await repo.saveSections(pieceId, share.sections);
            }
          case ShareConflictChoice.keepBoth:
            pieceId = freshPieceId();
            action = ShareScoreAction.create;
        }
      }
    } else {
      // A catalog piece this build doesn't ship gets an id of its own, so a
      // later build that does ship it can't end up listing the id twice.
      pieceId = m.bundled || repo.isBundled(m.pieceId)
          ? freshPieceId()
          : m.pieceId;
      action = ShareScoreAction.create;
    }
    if (action == ShareScoreAction.create) {
      await storage.saveScannedPieceAs(pieceId, m.title, share.musicXml);
      if (share.sections.isNotEmpty) {
        await repo.saveSections(pieceId, share.sections);
      }
    }
    // The sender's instrument layers: taken whole with a new or replaced
    // score, and only where this device has made no choice of its own when
    // the score was already the same.
    final layers = InstrumentLayerStore(root: docs);
    for (final MapEntry(key: id, value: incoming) in share.layers.entries) {
      final mine = action == ShareScoreAction.keep
          ? await layers.stringChoices(pieceId, id)
          : const <String, int>{};
      await layers.setStringChoices(pieceId, id, {...incoming, ...mine});
    }

    final store = PieceMediaStore();
    final have = await store.load(pieceId);
    final identical = <String>{};
    for (final incoming in m.media) {
      final mine = have.where((h) => h.id == incoming.id).firstOrNull;
      if (mine != null && await _sameRecording(share, incoming, mine, docs)) {
        identical.add(incoming.id);
      }
    }
    final plan = planShareImport(
      m,
      pieceId: pieceId,
      score: action,
      existing: have,
      identical: identical,
      freshMediaId: (i) => PieceMediaStore.newMediaId(
          'shared', at.add(Duration(milliseconds: i))),
    );

    final prefs = await SharedPreferences.getInstance();
    for (final p in plan.media) {
      for (final MapEntry(key: from, value: to) in p.files.entries) {
        final target = File('${docs.path}/$to');
        await target.parent.create(recursive: true);
        await File('${share._dir.path}/$from').copy(target.path);
      }
      await store.add(pieceId, p.media);
      if (p.alignment != null) {
        await prefs.setString(
            '$_alignmentPrefix${p.media.alignmentKey}', p.alignment!);
      }
    }
    // Only fill in what the receiver hasn't chosen for itself.
    for (final MapEntry(:key, :value) in m.display.entries) {
      final prefKey = 'display.$key.$pieceId';
      if (!prefs.containsKey(prefKey)) await prefs.setString(prefKey, value);
    }
    debugPrint('[share] imported "${m.title}" as $pieceId: '
        '${action.name}, ${plan.media.length} added, '
        '${plan.alreadyPresent} already here');
    return ShareImportResult(
      pieceId: pieceId,
      title: m.title,
      score: action,
      added: plan.media.length,
      alreadyPresent: plan.alreadyPresent,
    );
  }

  /// The same recording as one this device already has under that id: same
  /// label and kind, and the audio file the same size. Sizes, as the dev
  /// library compares media — a re-recording all but never matches to the
  /// byte.
  Future<bool> _sameRecording(OpenedShare share, PieceMedia incoming,
      PieceMedia mine, Directory docs) async {
    if (incoming.label != mine.label || incoming.kind != mine.kind) {
      return false;
    }
    final a = incoming.audio, b = mine.audio;
    if (a == null || b == null || b.isAsset) return false;
    final theirs = File('${share._dir.path}/${a.path}');
    final ours = File('${docs.path}/${b.path}');
    if (!await theirs.exists() || !await ours.exists()) return false;
    return await theirs.length() == await ours.length();
  }

  /// Deletes an incoming share file once imported, but only one the system
  /// put in this app's own `Documents/Inbox` (iOS) or cache (Android) — never
  /// a file the user opened in place from somewhere else.
  Future<void> discardIncoming(String path) async {
    final docs = await _docsDir();
    final temp = await _tempDir();
    final inOurs = path.startsWith('${docs.path}/Inbox/') ||
        path.startsWith('${temp.path}/');
    if (inOurs) await _deleteQuietly(File(path));
  }

  static Future<void> _deleteQuietly(FileSystemEntity e) async {
    try {
      if (await e.exists()) await e.delete(recursive: true);
    } catch (_) {}
  }
}

/// A share file unpacked to a temp folder.
class OpenedShare {
  OpenedShare._(
      this.manifest, this.musicXml, this.sections, this.layers, this._dir);

  final PieceShareManifest manifest;
  final String musicXml;
  final List<Section> sections;

  /// String choices per instrument layer, as the sender had them.
  final Map<String, Map<String, int>> layers;
  final Directory _dir;

  Future<void> dispose() => PieceShareIo._deleteQuietly(_dir);
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/piece_media.dart';

/// File-backed media exist on this platform.
const bool mediaFilesSupported = true;

/// Where user media lives under the documents directory: one folder per
/// medium, so deleting a medium is deleting a directory and can't strand a
/// sibling's files.
///
/// Recordings made before this layout existed stay where they were written
/// (`teacher_recordings/<pieceId>/`) — the migration stores their relative
/// path rather than moving files around, because moving a user's only copy of
/// a recording to fix a tidiness problem is a bad trade.
String mediaFolderFor(String pieceId, String mediaId) =>
    'media/$pieceId/$mediaId';

/// Turns a documents-relative path into an absolute one against the documents
/// directory **as it is right now**.
///
/// This is the whole point of [MediaRef] storing relative paths: the answer is
/// recomputed on every read, so a container that has moved since the path was
/// stored resolves correctly instead of throwing `PathNotFoundException`. See
/// [MediaRef]'s doc comment for the incident this comes from.
Future<String> resolveMediaPath(String relativePath) async {
  final docs = await getApplicationDocumentsDirectory();
  return '${docs.path}/$relativePath';
}

/// The absolute path a [MediaRef] names, or null for an asset ref (which has
/// no file-system path — read it with [readMediaBytes] instead).
Future<String?> absolutePathOf(MediaRef ref) async {
  if (ref.isAsset) return null;
  return resolveMediaPath(ref.path);
}

/// Whether the file a ref names is actually there. An `appFile` ref can
/// legitimately point at nothing — the user deleted the app's data, a restore
/// dropped it — and callers show "missing" rather than throwing.
Future<bool> mediaExists(MediaRef ref) async {
  if (ref.isAsset) {
    try {
      await rootBundle.load(ref.path);
      return true;
    } catch (_) {
      return false;
    }
  }
  return File(await resolveMediaPath(ref.path)).exists();
}

/// The whole file's bytes, from the asset bundle or from disk.
Future<Uint8List> readMediaBytes(MediaRef ref) async {
  if (ref.isAsset) {
    final data = await rootBundle.load(ref.path);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
  return File(await resolveMediaPath(ref.path)).readAsBytes();
}

/// Copies [sourcePath] into this medium's own folder and returns the
/// documents-RELATIVE path of the copy — which is what gets persisted.
///
/// A copy rather than a reference to wherever the picker found it: on iOS a
/// picked file commonly lands in a temporary inbox the system is free to
/// empty, so pointing at it would reproduce the disappearing-file bug this
/// whole model exists to prevent.
Future<String> importMediaFile({
  required String pieceId,
  required String mediaId,
  required String sourcePath,
  required String filename,
}) async {
  final relativeFolder = mediaFolderFor(pieceId, mediaId);
  final folder = Directory(await resolveMediaPath(relativeFolder));
  await folder.create(recursive: true);
  final relativePath = '$relativeFolder/$filename';
  await File(sourcePath).copy(await resolveMediaPath(relativePath));
  return relativePath;
}

/// Writes [bytes] into this medium's own folder; returns the relative path.
Future<String> writeMediaBytes({
  required String pieceId,
  required String mediaId,
  required String filename,
  required Uint8List bytes,
}) async {
  final relativeFolder = mediaFolderFor(pieceId, mediaId);
  final folder = Directory(await resolveMediaPath(relativeFolder));
  await folder.create(recursive: true);
  final relativePath = '$relativeFolder/$filename';
  await File(await resolveMediaPath(relativePath)).writeAsBytes(bytes);
  return relativePath;
}

/// Removes every file a medium owns. Best-effort and idempotent: a medium
/// whose files are already gone is exactly the case this has to cope with.
Future<void> deleteMediaFiles(PieceMedia media) async {
  final folder = Directory(
      await resolveMediaPath(mediaFolderFor(_pieceIdOf(media), media.id)));
  try {
    if (await folder.exists()) await folder.delete(recursive: true);
  } catch (_) {
    // A file we can't remove is disk noise, not a failed delete — the medium
    // still comes out of the piece's list, which is what the user asked for.
  }
  // Media migrated from the old `teacher_recordings/` layout live outside the
  // folder above, so remove their individual files too.
  for (final ref in [media.audio, media.analysis, media.video]) {
    if (ref == null || ref.isAsset) continue;
    if (ref.path.startsWith('media/')) continue;
    try {
      final file = File(await resolveMediaPath(ref.path));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Same reasoning as above.
    }
  }
}

/// A medium's folder is `media/<pieceId>/<mediaId>`, so the piece id is
/// recoverable from any of its own refs. Used only by [deleteMediaFiles],
/// which would otherwise need the piece id threaded through every caller for
/// the sake of one path.
String _pieceIdOf(PieceMedia media) {
  for (final ref in [media.audio, media.analysis, media.video]) {
    if (ref == null || ref.isAsset) continue;
    final parts = ref.path.split('/');
    if (parts.length >= 3 && parts[0] == 'media') return parts[1];
  }
  return '';
}

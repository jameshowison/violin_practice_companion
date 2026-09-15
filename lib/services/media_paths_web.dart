import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../models/piece_media.dart';

/// Web stub. Bundled tracks (asset refs) work exactly as they do everywhere
/// else; file-backed media do not exist, because there is no documents
/// directory to resolve a relative path against.
///
/// This is the same line `piece_storage_web.dart` and
/// `teacher_recording_capture_web.dart` already draw. Callers check
/// [mediaFilesSupported] before offering import or recording, so the throwing
/// methods below are unreachable rather than merely unlikely — they throw
/// instead of returning something plausible so a missed check fails loudly in
/// development rather than silently producing an empty medium.
const bool mediaFilesSupported = false;

String mediaFolderFor(String pieceId, String mediaId) =>
    'media/$pieceId/$mediaId';

Future<String> resolveMediaPath(String relativePath) async =>
    throw UnsupportedError('File-backed media are not available on the web.');

Future<String?> absolutePathOf(MediaRef ref) async => null;

/// Only an asset can exist here; an `appFile` ref on web is a leftover from
/// another platform's data and is reported missing rather than throwing.
Future<bool> mediaExists(MediaRef ref) async {
  if (!ref.isAsset) return false;
  try {
    await rootBundle.load(ref.path);
    return true;
  } catch (_) {
    return false;
  }
}

Future<Uint8List> readMediaBytes(MediaRef ref) async {
  if (!ref.isAsset) {
    throw UnsupportedError('File-backed media are not available on the web.');
  }
  final data = await rootBundle.load(ref.path);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<String> importMediaFile({
  required String pieceId,
  required String mediaId,
  required String sourcePath,
  required String filename,
}) async =>
    throw UnsupportedError('Importing media is not available on the web.');

Future<String> writeMediaBytes({
  required String pieceId,
  required String mediaId,
  required String filename,
  required Uint8List bytes,
}) async =>
    throw UnsupportedError('Importing media is not available on the web.');

Future<void> deleteMediaFiles(PieceMedia media) async {}

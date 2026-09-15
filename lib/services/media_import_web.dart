import '../models/piece_media.dart';
import 'media_paths.dart';

/// Web stub. Mirrors the io result type so the shared call site in the media
/// tray compiles; `isSupported` is false there, so the "Add audio or video"
/// entry never appears and nothing below is reached.
class MediaImportResult {
  final PieceMedia? media;
  final String? error;

  const MediaImportResult.imported(PieceMedia this.media) : error = null;
  const MediaImportResult.cancelled()
      : media = null,
        error = null;
  const MediaImportResult.failed(String this.error) : media = null;

  bool get isCancelled => media == null && error == null;
}

class MediaImporter {
  const MediaImporter();

  /// Always false: an imported medium is a file under the documents directory,
  /// and there isn't one. See media_paths_web.dart.
  bool get isSupported => mediaFilesSupported;

  static const List<String> supportedExtensions = [];

  Future<MediaImportResult> pickAndImport({required String pieceId}) async =>
      const MediaImportResult.failed(
          'Importing audio and video is not available on the web.');

  Future<MediaImportResult> importPath({
    required String pieceId,
    required String sourcePath,
    required String filename,
    required DateTime now,
  }) async =>
      const MediaImportResult.failed(
          'Importing audio and video is not available on the web.');
}

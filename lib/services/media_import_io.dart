import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/piece_media.dart';
import 'audio_decoder_base.dart';
import 'media_migration.dart';
import 'media_paths.dart';
import 'piece_media_store.dart';

/// The outcome of an import attempt, so the caller can tell "user changed
/// their mind" from "that file is no good" and say the right thing.
class MediaImportResult {
  final PieceMedia? media;

  /// Null when [media] is non-null or the user simply cancelled.
  final String? error;

  const MediaImportResult.imported(PieceMedia this.media) : error = null;
  const MediaImportResult.cancelled()
      : media = null,
        error = null;
  const MediaImportResult.failed(String this.error) : media = null;

  bool get isCancelled => media == null && error == null;
}

/// Brings a file the user already has into the app as a [PieceMedia].
///
/// The imported file is COPIED into the medium's own folder rather than
/// referenced where it sits. On iOS a picked file commonly lands in a
/// temporary inbox the system may empty at any time, so referencing it would
/// recreate exactly the vanishing-file failure that [MediaRef] exists to
/// prevent — and would do it for a file the user believes they have added to
/// the app.
class MediaImporter {
  const MediaImporter();

  bool get isSupported => mediaFilesSupported;

  /// Every extension the picker will accept.
  static final List<String> supportedExtensions = [
    ...importableAudioExtensions,
    ...importableVideoExtensions,
  ];

  /// Opens the system picker and, if a usable file comes back, copies it in.
  ///
  /// The picker is opened with [FileType.any] and the extension checked
  /// afterwards, rather than with `FileType.custom`: iOS maps custom
  /// extensions to UTIs and silently refuses to show anything it can't map,
  /// which presents as an empty file browser with no explanation. Validating
  /// here means an unsupported choice gets a sentence saying so.
  Future<MediaImportResult> pickAndImport({required String pieceId}) async {
    final FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(type: FileType.any);
    } catch (e) {
      return MediaImportResult.failed("Couldn't open the file picker: $e");
    }
    if (picked == null || picked.files.isEmpty) {
      return const MediaImportResult.cancelled();
    }

    final file = picked.files.single;
    final sourcePath = file.path;
    if (sourcePath == null) {
      return const MediaImportResult.failed(
          "That file couldn't be read from this device.");
    }

    final filename = file.name.isEmpty
        ? sourcePath.split(Platform.pathSeparator).last
        : file.name;
    final extension = _extensionOf(filename);
    if (!supportedExtensions.contains(extension)) {
      return MediaImportResult.failed(
        extension.isEmpty
            ? "That file has no extension, so there's no way to tell what it is."
            : "'.$extension' files aren't supported. Try ${supportedExtensions.join(', ')}.",
      );
    }

    return importPath(
      pieceId: pieceId,
      sourcePath: sourcePath,
      filename: filename,
      now: DateTime.now(),
    );
  }

  /// The half of [pickAndImport] that does not involve a picker — the copy and
  /// the [PieceMedia] construction. Separate so it can be driven directly (by
  /// a test, or by a caller that already has a path).
  Future<MediaImportResult> importPath({
    required String pieceId,
    required String sourcePath,
    required String filename,
    required DateTime now,
  }) async {
    final extension = _extensionOf(filename);
    final mediaId = PieceMediaStore.newMediaId('import', now);
    final String relativePath;
    try {
      relativePath = await importMediaFile(
        pieceId: pieceId,
        mediaId: mediaId,
        sourcePath: sourcePath,
        filename: 'source.$extension',
      );
    } catch (e) {
      return MediaImportResult.failed("Couldn't copy that file in: $e");
    }

    final ref = MediaRef.appFile(relativePath);
    final isVideo = isVideoExtension(extension);
    return MediaImportResult.imported(PieceMedia(
      id: mediaId,
      // The user's own filename, minus the extension — it is how they think of
      // the file, and a list of "source.mp3" tells them nothing.
      label: _labelFor(filename),
      kind: MediaKind.imported,
      alignmentKey: MediaMigration.bundledlessAlignmentKey(pieceId, mediaId),
      audio: ref,
      // The same file is the analysis source: a video's audio track is what
      // gets decoded, which is what makes an imported mp4 behave exactly like
      // a recorded demo.
      analysis: ref,
      video: isVideo ? ref : null,
      // Audio and video are the same file here, so there is nothing to offset —
      // unlike a capture, where two recorders are started back to back.
      avOffsetMs: 0,
    ));
  }

  static String _labelFor(String filename) {
    final dot = filename.lastIndexOf('.');
    final stem = dot <= 0 ? filename : filename.substring(0, dot);
    return stem.isEmpty ? filename : stem;
  }

  static String _extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return '';
    return filename.substring(dot + 1).toLowerCase();
  }
}

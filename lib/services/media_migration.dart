import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/piece_media.dart';
import 'media_alignment_store.dart';
import 'piece_media_store.dart';

/// Brings a device's pre-[PieceMedia] data forward, in place, on first read.
///
/// Two legacy prefs blobs are involved and neither carries a schema version,
/// nor is there any hook to bump one — so this cannot be a versioned upgrade
/// step and has to be inferable from the keys themselves:
///
///   * `audioSyncAnchors.<pieceId>` — a bundled Play Along track's anchors.
///     Moves to this piece's bundled alignment key, so an already-aligned
///     piece does not silently re-run its one-time alignment.
///   * `teacherRecording.<pieceId>` — a recorded demo's ABSOLUTE file paths,
///     AV offset and anchors. Becomes one [PieceMedia] with relative refs,
///     plus an alignment row.
///
/// Both migrations are skipped when their destination already exists, so this
/// is idempotent and costs two in-memory prefs lookups per piece on every
/// later load. Nothing is ever deleted: the legacy keys are left where they
/// are, so a build from before this change still finds its data if the user
/// rolls back.
class MediaMigration {
  const MediaMigration();

  /// The path segment every legacy recording was written under. Searching for
  /// it beats stripping a known documents prefix, because that prefix differs
  /// by platform (`.../Documents/` on iOS, `.../app_flutter/` on Android) and
  /// the whole problem is that the absolute part is the untrustworthy part.
  static const legacyRecordingFolder = 'teacher_recordings/';

  /// Turns a stored absolute recording path into a documents-relative one.
  ///
  /// Returns null when the path contains no recognizable anchor, which is the
  /// honest answer for a path this code has no way to place — the caller then
  /// treats the recording as absent, the same as every other unreadable
  /// stored value in this area. An already-relative path passes through
  /// unchanged (the anchor is found at index 0).
  static String? relativizeLegacyPath(String path) {
    final i = path.indexOf(legacyRecordingFolder);
    return i < 0 ? null : path.substring(i);
  }

  /// The media id a migrated recording gets. Stable, so re-running the
  /// migration can recognize its own output.
  static const migratedRecordingId = 'teacher_demo';

  /// Copies a piece's legacy bundled-track anchors onto [alignmentKey] if
  /// that key has nothing yet. No-op when the piece never had bundled tracks
  /// or was never aligned.
  Future<void> migrateBundledAnchors(
      String pieceId, String alignmentKey) async {
    final prefs = await SharedPreferences.getInstance();
    final destination = 'mediaAlignment.$alignmentKey';
    if (prefs.containsKey(destination)) return;
    final legacy = prefs.getString('audioSyncAnchors.$pieceId');
    if (legacy == null) return;
    // Re-encoded through the store rather than copied verbatim, so a blob
    // that would not parse now is dropped here instead of being carried
    // forward to fail later, further from its cause.
    final alignment = MediaAlignmentStore.decode(legacy);
    if (alignment == null) return;
    await MediaAlignmentStore().save(alignmentKey, alignment);
  }

  /// Converts a legacy teacher recording into a user medium, if one exists and
  /// this piece has no user media yet.
  ///
  /// Returns the migrated medium, or null when there was nothing to do. The
  /// caller appends it to the piece's list; the files themselves are not
  /// moved — see `mediaFolderFor`.
  Future<PieceMedia?> migrateTeacherRecording(String pieceId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey('pieceMedia.$pieceId')) return null;
    final raw = prefs.getString('teacherRecording.$pieceId');
    if (raw == null) return null;

    final alignment = MediaAlignmentStore.decode(raw);
    final legacy = _decodeLegacyPaths(raw);
    // An unparseable legacy blob is treated as "no recording" — the same
    // policy the old store applied, where any parse failure returned null and
    // re-recording was the only recovery.
    if (alignment == null || legacy == null) return null;

    final audio = MediaRef.appFile(legacy.audioPath);
    final media = PieceMedia(
      id: migratedRecordingId,
      label: 'Teacher demo',
      kind: MediaKind.recorded,
      alignmentKey: bundledlessAlignmentKey(pieceId, migratedRecordingId),
      audio: audio,
      // The capture wrote WAV specifically so it could feed DTW, so the
      // recording is its own analysis source.
      analysis: audio,
      video:
          legacy.videoPath == null ? null : MediaRef.appFile(legacy.videoPath!),
      avOffsetMs: legacy.avOffsetMs,
    );

    await MediaAlignmentStore().save(media.alignmentKey, alignment);
    await PieceMediaStore().save(pieceId, [media]);
    return media;
  }

  /// The alignment key for a medium with a timeline of its own — anything
  /// that is not one of a piece's bundled mixes.
  static String bundledlessAlignmentKey(String pieceId, String mediaId) =>
      'media:$pieceId:$mediaId';

  /// The alignment key shared by a piece's bundled `mix`/`melody`/`chords`.
  /// Keyed on the AUDIO FOLDER, not the piece, because the folder is what the
  /// three tracks actually have in common.
  static String bundledAlignmentKey(String audioFolder) =>
      'bundled:$audioFolder';

  /// Reads only the fields [MediaAlignmentStore.decode] does not: the two file
  /// paths and the AV offset.
  _LegacyRecordingPaths? _decodeLegacyPaths(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final audio = json['audioPath'];
      if (audio is! String) return null;
      final audioRelative = relativizeLegacyPath(audio);
      if (audioRelative == null) return null;
      final video = json['videoPath'];
      return _LegacyRecordingPaths(
        audioPath: audioRelative,
        videoPath: video is String ? relativizeLegacyPath(video) : null,
        avOffsetMs: (json['avOffsetMs'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

class _LegacyRecordingPaths {
  final String audioPath;
  final String? videoPath;
  final int avOffsetMs;

  const _LegacyRecordingPaths({
    required this.audioPath,
    required this.videoPath,
    required this.avOffsetMs,
  });
}

/// A shared piece: what one device sends another over AirDrop (or Messages,
/// Mail, Quick Share — anything the system share sheet offers) as a
/// `.stringlings` file.
///
/// The file is a zip:
///
/// ```text
/// bundle.json            this manifest
/// score.musicxml         the piece as the sender plays it (always sent,
///                        even for a bundled piece — see [bundled])
/// sections.json          {"sections": [...]}, when the piece has any
/// instrument_layers/<instrumentId>.json  {"stringChoices": {...}}, each
///                        instrument layer the piece has (`InstrumentLayerStore`)
/// media/<mediaId>/<file> each shared recording's files
/// ```
///
/// Media paths are BUNDLE-relative here (`media/<mediaId>/<file>`), not the
/// sender's Documents layout: the receiver re-homes every file under its own
/// `media/<pieceId>/<mediaId>/`, so a recording made before that layout
/// existed (`teacher_recordings/…`) arrives in the current one.
///
/// Pure Dart, no `dart:io`: the zip and the file copies are
/// `piece_share_io.dart`'s job. This file decides what goes where.
library;

import '../models/piece_media.dart';
import 'media_migration.dart';

/// The share file's extension, and (on iOS) the declared type's tag.
const String kShareFileExtension = 'stringlings';

/// Bumped only for a change an older reader would misread.
const int kShareBundleFormat = 1;

const String kShareManifestName = 'bundle.json';
const String kShareScoreName = 'score.musicxml';
const String kShareSectionsName = 'sections.json';
const String kShareLayersDir = 'instrument_layers';

/// The `display.<name>.<pieceId>` settings that travel with a piece — the same
/// two the dev library carries (`devLibrarySyncedDisplay`): how its numbers
/// read is a property of the repertoire, not of the device.
const Set<String> kSharedDisplayPrefs = {'numbers', 'fretStyle'};

class PieceShareManifest {
  PieceShareManifest({
    required this.pieceId,
    required this.title,
    required this.bundled,
    required this.hasSections,
    required this.media,
    this.alignments = const {},
    this.display = const {},
    this.format = kShareBundleFormat,
  });

  final int format;

  /// The sender's id. Kept on the receiver where it can be, so sharing the
  /// same piece again later adds to it instead of making a second copy.
  final String pieceId;
  final String title;

  /// A catalog piece on the sender. The receiver uses the id as-is only when
  /// its own build ships that piece too; otherwise the score is saved as a
  /// user piece under a fresh id (one that can't collide with the catalog
  /// entry should a later build add it).
  final bool bundled;
  final bool hasSections;

  /// Each shared medium, with bundle-relative paths.
  final List<PieceMedia> media;

  /// Media id → the cached alignment, as the raw `mediaAlignment.*` pref
  /// string. Raw, as the dev library carries it, so nothing is re-encoded.
  final Map<String, String> alignments;

  /// Display-pref name ([kSharedDisplayPrefs]) → stored value.
  final Map<String, String> display;

  Map<String, Object?> toJson() => {
        'format': format,
        'piece': {
          'id': pieceId,
          'title': title,
          'bundled': bundled,
          'hasSections': hasSections,
        },
        'media': [for (final m in media) m.toJson()],
        'alignments': alignments,
        'display': display,
      };

  /// Throws [FormatException] for anything that isn't a bundle this build can
  /// read — including one from a newer format, which is better refused with a
  /// clear message than half-imported.
  static PieceShareManifest fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Not a shared piece');
    final format = json['format'];
    if (format is! int) throw const FormatException('Not a shared piece');
    if (format > kShareBundleFormat) {
      throw const FormatException(
          'This piece was shared from a newer version of the app. '
          'Update the app to open it.');
    }
    final piece = json['piece'];
    if (piece is! Map ||
        piece['id'] is! String ||
        (piece['id'] as String).isEmpty ||
        piece['title'] is! String) {
      throw const FormatException('The shared piece has no id or title');
    }
    final id = piece['id'] as String;
    if (!isSafeId(id)) throw const FormatException('Bad piece id');

    final media = <PieceMedia>[];
    for (final row in (json['media'] as List?) ?? const []) {
      final m = PieceMedia.fromJson(row);
      if (m == null || !m.isRemovable || !isSafeId(m.id)) continue;
      // Every file a row names must be one of its own, inside the bundle.
      final refs = [m.audio, m.analysis, m.video];
      if (refs.any((r) => r != null && !_isOwnBundlePath(r, m.id))) continue;
      media.add(m);
    }
    return PieceShareManifest(
      format: format,
      pieceId: id,
      title: piece['title'] as String,
      bundled: piece['bundled'] == true,
      hasSections: piece['hasSections'] == true,
      media: media,
      alignments: {
        for (final MapEntry(:key, :value)
            in ((json['alignments'] as Map?) ?? const {}).entries)
          if (key is String && value is String) key: value,
      },
      display: {
        for (final MapEntry(:key, :value)
            in ((json['display'] as Map?) ?? const {}).entries)
          if (kSharedDisplayPrefs.contains(key) && value is String) key: value,
      },
    );
  }

  /// A file path inside the bundle that belongs to medium [mediaId]:
  /// exactly `media/<mediaId>/<name>`, no traversal.
  static bool _isOwnBundlePath(MediaRef ref, String mediaId) {
    if (ref.isAsset) return false;
    final parts = ref.path.split('/');
    return parts.length == 3 &&
        parts[0] == 'media' &&
        parts[1] == mediaId &&
        isSafeFileName(parts[2]);
  }
}

/// Ids name folders and files on the receiver, so they are held to the
/// characters the app itself generates (`<slug>_<millis>`, `demo_<millis>`).
bool isSafeId(String id) =>
    id.isNotEmpty && id.length <= 200 && RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(id);

bool isSafeFileName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.startsWith('.') &&
    !name.contains('/') &&
    !name.contains(r'\');

// ── Export ──────────────────────────────────────────────────────────────────

/// One recording as the sender chose to share it.
class ShareMediaChoice {
  const ShareMediaChoice(this.media, {this.includeVideo = true});
  final PieceMedia media;
  final bool includeVideo;
}

/// What to put in the zip: the shared rows (bundle paths) and, for each
/// bundle path, the sender's Documents-relative file to copy there.
class ShareExportPlan {
  ShareExportPlan(this.media, this.files);
  final List<PieceMedia> media;

  /// Bundle path → sender's Documents-relative path.
  final Map<String, String> files;
}

/// Rewrites each chosen medium's files to `media/<mediaId>/<basename>`.
///
/// Leaving a video out drops only the row's `video`; a file that is also the
/// audio (an imported .mp4 is both) still goes, since the row needs it. Rows
/// with nothing playable left — no audio — are dropped.
ShareExportPlan planShareExport(List<ShareMediaChoice> choices) {
  final media = <PieceMedia>[];
  final files = <String, String>{};
  for (final choice in choices) {
    final m = choice.media;
    if (!m.isRemovable || m.audio == null || m.audio!.isAsset) continue;
    // Source path → bundle path, so a file that is audio AND analysis (or
    // audio AND video) is sent once and every ref points at the one copy.
    final placed = <String, String>{};
    MediaRef? place(MediaRef? ref) {
      if (ref == null || ref.isAsset) return null;
      final existing = placed[ref.path];
      if (existing != null) return MediaRef.appFile(existing);
      var name = ref.path.split('/').last;
      if (!isSafeFileName(name)) name = 'file';
      // Two different sources with one basename (possible only for a legacy
      // layout) must not overwrite each other in the zip.
      var bundlePath = 'media/${m.id}/$name';
      for (var i = 2; placed.containsValue(bundlePath); i++) {
        bundlePath = 'media/${m.id}/${i}_$name';
      }
      placed[ref.path] = bundlePath;
      files[bundlePath] = ref.path;
      return MediaRef.appFile(bundlePath);
    }

    final audio = place(m.audio);
    final analysis = place(m.analysis);
    final video = choice.includeVideo ? place(m.video) : null;
    media.add(PieceMedia(
      id: m.id,
      label: m.label,
      kind: m.kind,
      alignmentKey: m.alignmentKey,
      audio: audio,
      analysis: analysis,
      video: video,
      avOffsetMs: video == null ? 0 : m.avOffsetMs,
      contentStartSeconds: m.contentStartSeconds,
      contentEndSeconds: m.contentEndSeconds,
    ));
  }
  return ShareExportPlan(media, files);
}

/// A file name for the share: the title, made safe, with the extension.
String shareFileNameFor(String title) {
  var base = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (base.startsWith('.')) base = base.replaceFirst(RegExp(r'^\.+'), '');
  if (base.isEmpty) base = 'Piece';
  if (base.length > 80) base = base.substring(0, 80).trim();
  return '$base.$kShareFileExtension';
}

// ── Import ──────────────────────────────────────────────────────────────────

/// What happens to the score on the receiving side.
enum ShareScoreAction {
  /// The receiver has no such piece: create it.
  create,

  /// The receiver's score is the same: leave it, add recordings only.
  keep,

  /// The receiver chose to overwrite its score with the shared one.
  replace,
}

/// One incoming medium, ready to write.
class PlannedShareMedia {
  PlannedShareMedia(this.media, this.files, this.alignment);

  /// The row as the receiver stores it: Documents-relative paths, the
  /// receiver's piece id in its alignment key.
  final PieceMedia media;

  /// Bundle path → receiver's Documents-relative path.
  final Map<String, String> files;

  /// The raw alignment to store under [PieceMedia.alignmentKey], if sent.
  final String? alignment;
}

class ShareImportPlan {
  ShareImportPlan({
    required this.pieceId,
    required this.score,
    required this.media,
    required this.alreadyPresent,
  });

  /// The piece the media land on: the sender's id, or a fresh one.
  final String pieceId;
  final ShareScoreAction score;
  final List<PlannedShareMedia> media;

  /// Shared recordings the receiver already had, and so skipped.
  final int alreadyPresent;
}

/// Decides where each incoming medium goes on the receiver.
///
/// [existing] is the receiver's stored media for [pieceId] (empty for a new
/// piece). An incoming id the receiver already holds is either the same
/// recording — listed in [identical], decided by the io side from file sizes
/// — and skipped, or a different one that happens to share the id (the
/// migration's fixed `teacher_demo`, say), which arrives under
/// [freshMediaId] instead of overwriting it.
ShareImportPlan planShareImport(
  PieceShareManifest manifest, {
  required String pieceId,
  required ShareScoreAction score,
  required List<PieceMedia> existing,
  required Set<String> identical,
  required String Function(int index) freshMediaId,
}) {
  final taken = {for (final m in existing) m.id};
  final planned = <PlannedShareMedia>[];
  var skipped = 0, fresh = 0;
  for (final m in manifest.media) {
    var id = m.id;
    if (taken.contains(id)) {
      if (identical.contains(id)) {
        skipped++;
        continue;
      }
      do {
        id = freshMediaId(fresh++);
      } while (taken.contains(id));
    }
    taken.add(id);

    final files = <String, String>{};
    MediaRef? rehome(MediaRef? ref) {
      if (ref == null) return null;
      final name = ref.path.split('/').last;
      final target = 'media/$pieceId/$id/$name';
      files[ref.path] = target;
      return MediaRef.appFile(target);
    }

    final row = PieceMedia(
      id: id,
      label: m.label,
      kind: m.kind,
      alignmentKey: MediaMigration.bundledlessAlignmentKey(pieceId, id),
      audio: rehome(m.audio),
      analysis: rehome(m.analysis),
      video: rehome(m.video),
      avOffsetMs: m.avOffsetMs,
      contentStartSeconds: m.contentStartSeconds,
      contentEndSeconds: m.contentEndSeconds,
    );
    planned.add(PlannedShareMedia(row, files, manifest.alignments[m.id]));
  }
  return ShareImportPlan(
    pieceId: pieceId,
    score: score,
    media: planned,
    alreadyPresent: skipped,
  );
}

/// Whether two scores are the same piece as written, ignoring only
/// whitespace at the ends and line-ending style.
bool sameScore(String a, String b) =>
    a.replaceAll('\r\n', '\n').trim() == b.replaceAll('\r\n', '\n').trim();

/// The receiver's answer when it has the piece with a different score.
enum ShareConflictChoice { replace, keepBoth }

class ShareImportResult {
  const ShareImportResult({
    required this.pieceId,
    required this.title,
    required this.score,
    required this.added,
    required this.alreadyPresent,
  });

  final String pieceId;
  final String title;
  final ShareScoreAction score;
  final int added;
  final int alreadyPresent;
}

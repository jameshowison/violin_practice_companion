import '../models/audio_track_variant.dart';
import '../models/piece_media.dart';
import 'media_migration.dart';
import 'piece_media_store.dart';

/// Assembles the full list of media a piece can be played by, from the three
/// places they come from: the score itself, the asset bundle, and whatever the
/// user has added.
///
/// This is the seam the rest of the app talks to. Nothing above it needs to
/// know that bundled tracks are looked up in a hardcoded folder map while user
/// media live in prefs, or that a device upgrading from an older build has a
/// recording to bring forward — the list that comes out is the list, in the
/// order it should be offered.
class MediaCatalog {
  MediaCatalog({PieceMediaStore? store, MediaMigration? migration})
      : _store = store ?? PieceMediaStore(),
        _migration = migration ?? const MediaMigration();

  final PieceMediaStore _store;
  final MediaMigration _migration;

  /// The bundled `mix`/`melody`/`chords` tracks in `assets/audio/<folder>/`.
  ///
  /// All three share one [PieceMedia.alignmentKey], because they are three
  /// mixes of a single recording session and therefore one timeline — the
  /// alignment runs once and serves whichever the user listens to.
  ///
  /// All three also share one ANALYSIS source, and it is always `melody.wav`
  /// regardless of which is playing: it is the closest match to the score's
  /// own notes and so the best-conditioned DTW reference. (It is also the only
  /// WAV in the folder — the others ship as mp3 — which is no longer a
  /// constraint now that [AudioDecoder] exists, but is still the right choice.)
  static List<PieceMedia> bundledMediaFor(String audioFolder) {
    final analysis =
        MediaRef.asset('assets/audio/$audioFolder/${AudioTrackVariant.melody.id}.wav');
    return [
      for (final variant in AudioTrackVariant.values)
        PieceMedia(
          id: 'bundled_${variant.id}',
          label: variant.label,
          kind: MediaKind.bundled,
          alignmentKey: MediaMigration.bundledAlignmentKey(audioFolder),
          audio: MediaRef.asset(variant.assetPathIn(audioFolder)),
          analysis: analysis,
        ),
    ];
  }

  /// Everything [pieceId] can be played by, in the order the picker shows it:
  /// the synthesized score first, then any bundled tracks, then the user's own
  /// media oldest-first.
  ///
  /// [audioFolder] is the piece's `assets/audio/<folder>/`, or null if it has
  /// none — see `PieceRepository.audioSyncFolderFor`.
  ///
  /// Runs the legacy migrations on the way past. They are idempotent and cost
  /// two in-memory prefs lookups once the first call has been made, so there is
  /// no separate "migrate on startup" step to forget to call.
  Future<List<PieceMedia>> mediaFor(String pieceId,
      {required String? audioFolder}) async {
    if (audioFolder != null) {
      await _migration.migrateBundledAnchors(
          pieceId, MediaMigration.bundledAlignmentKey(audioFolder));
    }
    await _migration.migrateTeacherRecording(pieceId);

    return [
      // Always present, always first: the one medium every piece has, and the
      // one the app can offer before anything has been recorded or imported.
      PieceMedia.synthesized,
      if (audioFolder != null) ...bundledMediaFor(audioFolder),
      ...await _store.load(pieceId),
    ];
  }

  /// The medium [id] names, or the synthesized score when it names nothing —
  /// so a selection that outlives its medium (deleted, or a piece that no
  /// longer has bundled tracks) falls back to something playable instead of
  /// leaving the tray empty.
  static PieceMedia resolve(List<PieceMedia> media, String? id) {
    if (id == null) return PieceMedia.synthesized;
    for (final m in media) {
      if (m.id == id) return m;
    }
    return PieceMedia.synthesized;
  }
}

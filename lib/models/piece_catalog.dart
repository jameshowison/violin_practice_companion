/// The bundled piece catalog, `assets/library/catalog.json`: which pieces ship
/// with the app, where their files are, and where the music comes from.
///
/// Pure data. Loaded once by `PieceRepository`; checked in
/// `test/release_content_test.dart`, which is what keeps every bundled file
/// listed here and every entry's provenance filled in.
library;

/// Where the catalog and every path in it live.
const String kLibraryAssetDir = 'assets/library';
const String kCatalogAsset = '$kLibraryAssetDir/catalog.json';

/// Licences a bundled item may carry. [internalTestingOnly] is allowed in a
/// TestFlight-style build for known testers and refused for a public release
/// (see `test/release_content_test.dart`, `VPC_PUBLIC_RELEASE`).
abstract final class CatalogLicense {
  static const publicDomain = 'public-domain';
  static const cc0 = 'cc0';
  static const ccBy = 'cc-by';
  static const ccBySa = 'cc-by-sa';

  /// Our own work, under the project's licence (GPL-3.0).
  static const project = 'project';
  static const internalTestingOnly = 'internal-testing-only';

  static const all = {publicDomain, cc0, ccBy, ccBySa, project, internalTestingOnly};
  static const publicRelease = {publicDomain, cc0, ccBy, ccBySa, project};
}

/// A piece's bundled play-along tracks: `assets/library/<folder>/audio/`.
class CatalogAudio {
  const CatalogAudio({
    required this.folder,
    required this.source,
    required this.license,
  });

  /// The audio's identity as well as its location — cached alignments are
  /// keyed `bundled:<folder>` (`MediaMigration.bundledAlignmentKey`), so it
  /// must not change once tracks have shipped.
  final String folder;
  final String source;
  final String license;

  factory CatalogAudio.fromJson(Map<String, dynamic> j) => CatalogAudio(
        folder: j['folder'] as String,
        source: j['source'] as String? ?? '',
        license: j['license'] as String? ?? '',
      );
}

class CatalogPiece {
  const CatalogPiece({
    required this.id,
    required this.title,
    required this.composer,
    required this.score,
    required this.sections,
    required this.source,
    required this.license,
    required this.fingerings,
    this.audio,
  });

  final String id;
  final String title;
  final String composer;

  /// Relative to [kLibraryAssetDir]; see [scoreAsset] / [sectionsAsset].
  final String score;
  final String sections;
  final String source;
  final String license;

  /// Where any `<fingering>` in the score comes from: `app` (the score has
  /// none; the app generates them) or `cleared` (the file's own, with a
  /// licence that allows it).
  final String fingerings;
  final CatalogAudio? audio;

  String get scoreAsset => '$kLibraryAssetDir/$score';
  String get sectionsAsset => '$kLibraryAssetDir/$sections';

  factory CatalogPiece.fromJson(Map<String, dynamic> j) => CatalogPiece(
        id: j['id'] as String,
        title: j['title'] as String,
        composer: j['composer'] as String? ?? '',
        score: j['score'] as String,
        sections: j['sections'] as String,
        source: j['source'] as String? ?? '',
        license: j['license'] as String? ?? '',
        fingerings: j['fingerings'] as String? ?? '',
        audio: j['audio'] == null
            ? null
            : CatalogAudio.fromJson(j['audio'] as Map<String, dynamic>),
      );
}

/// Bundled tracks for a piece that is not itself bundled (a dev-library
/// piece, keyed by its opaque id).
class CatalogAudioOnly {
  const CatalogAudioOnly({required this.pieceId, required this.audio});

  final String pieceId;
  final CatalogAudio audio;

  factory CatalogAudioOnly.fromJson(Map<String, dynamic> j) => CatalogAudioOnly(
        pieceId: j['pieceId'] as String,
        audio: CatalogAudio.fromJson(j),
      );
}

class PieceCatalog {
  const PieceCatalog({required this.pieces, this.audioOnly = const []});

  final List<CatalogPiece> pieces;
  final List<CatalogAudioOnly> audioOnly;

  factory PieceCatalog.fromJson(Map<String, dynamic> j) => PieceCatalog(
        pieces: [
          for (final p in (j['pieces'] as List? ?? const []))
            CatalogPiece.fromJson(p as Map<String, dynamic>),
        ],
        audioOnly: [
          for (final a in (j['audioOnly'] as List? ?? const []))
            CatalogAudioOnly.fromJson(a as Map<String, dynamic>),
        ],
      );

  Set<String> get ids => {for (final p in pieces) p.id};

  /// Piece id → its bundled audio folder, for every piece that has one.
  Map<String, String> get audioFolders => {
        for (final p in pieces)
          if (p.audio != null) p.id: p.audio!.folder,
        for (final a in audioOnly) a.pieceId: a.audio.folder,
      };

  /// Every audio entry, bundled piece or not.
  Iterable<CatalogAudio> get allAudio => [
        for (final p in pieces)
          if (p.audio != null) p.audio!,
        for (final a in audioOnly) a.audio,
      ];
}

/// `assets/library/<folder>/audio/` — where a folder's tracks are bundled.
String bundledAudioDir(String folder) => '$kLibraryAssetDir/$folder/audio';

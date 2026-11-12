import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/piece.dart';
import '../models/piece_catalog.dart';
import '../models/section.dart';
import 'musicxml_beamer.dart';
import 'musicxml_normalizer.dart';
import 'musicxml_parser.dart';
import 'launch_timing.dart';
import 'piece_storage.dart';
import 'section_detector.dart';

class PieceRepository {
  /// [storage] is injectable so the persistence layer can be exercised in tests
  /// against a temp directory (see `test/piece_storage_io_test.dart`); production
  /// takes the platform default via the `piece_storage.dart` conditional import.
  PieceRepository({PieceStorage? storage, AssetBundle? bundle})
      : _storage = storage ?? PieceStorage(),
        _bundle = bundle ?? rootBundle;

  final PieceStorage _storage;
  final AssetBundle _bundle;

  // What ships, and where it comes from, is assets/library/catalog.json — see
  // [PieceCatalog]. Two of its pieces are there for what they exercise, not
  // just as tunes:
  //
  // Old Joe Clark and The Wellerman were converted from `docs/wellerman.abc`
  // through the app's own ABC pipeline and then through [_repair], so they
  // arrive in the same sounding-led, beamed form as the others — which is what
  // keeps them byte-identical under the normalizer and beamer round-trip tests.
  //
  // Old Joe Clark carries `<harmony>`, so it exercises the chord lane and the
  // "New chords" diagrams out of the box. It is also A MIXOLYDIAN, not D major:
  // both spell two sharps, so a `<mode>` that goes missing still engraves
  // correctly and surfaces only in the roman numerals, with A reading as V of D
  // instead of I. That is a real bug this tune has already caught once — keep
  // the mode.
  //
  // The Wellerman has no chords at all. It earns its place as the modal minor
  // counterpart, and as the case where the phone's tray correctly declines to
  // offer a drawer.

  PieceCatalog? _catalog;
  Future<PieceCatalog>? _catalogLoad;

  /// The bundled catalog, read once from [kCatalogAsset].
  Future<PieceCatalog> catalog() => _catalogLoad ??= () async {
        final raw = await _bundle.loadString(kCatalogAsset);
        return _catalog =
            PieceCatalog.fromJson(json.decode(raw) as Map<String, dynamic>);
      }();

  /// Whether [id] is a bundled piece.
  ///
  /// The ONLY reliable way to tell a bundled piece from a user-added one. It is
  /// tempting to test `musicXmlAssetPath != null` instead, and that is wrong:
  /// once a bundled piece has been edited, [loadAll] re-points it at its
  /// writable copy in `editable_fixtures/`, so an edited piece is
  /// field-for-field indistinguishable from a scan. Hide-vs-delete must branch
  /// on this.
  ///
  /// Synchronous, so it needs the catalog already read — which it always is by
  /// the time there is a piece to ask about, since [loadAll] reads it first.
  bool isBundled(String id) {
    final c = _catalog;
    if (c == null) {
      throw StateError('isBundled($id) before the catalog was loaded');
    }
    return c.ids.contains(id);
  }

  /// The audio folder (`assets/library/<folder>/audio/`, see
  /// [bundledAudioDir]) holding this piece's Play Along tracks, or null if it
  /// has none. Non-null-ness alone is "does Play Along exist for this piece" —
  /// per-track alignment state is separate, see [AudioSyncAnchorsStore]. A
  /// lookup rather than a [Piece] field because a dev-library piece can have
  /// bundled tracks too (the catalog's `audioOnly`), keyed by its opaque id.
  Future<String?> audioSyncFolderFor(String id) async =>
      (await catalog()).audioFolders[id];

  /// The catalog's composer for a bundled piece, or null (user pieces, or a
  /// blank entry). The piece list's fallback when the score names none.
  Future<String?> composerFor(String id) async {
    for (final p in (await catalog()).pieces) {
      if (p.id == id) return p.composer.isEmpty ? null : p.composer;
    }
    return null;
  }

  /// Whether the current platform supports editing (writable file storage).
  bool get supportsEditing => storageSupportsEditing;

  Future<List<Piece>> loadAll() async {
    final pieces = <Piece>[];
    final bundled = (await catalog()).pieces;
    for (final f in bundled) {
      // Prefer an edited section override (sidecar) over the bundled asset, so
      // section edits persist; un-edited fixtures track the bundled asset.
      final override = await _storage.loadSectionsOverride(f.id);
      final List<Section> sections;
      if (override != null) {
        sections = override.map(Section.fromJson).toList();
      } else {
        final sectionsRaw = await _bundle.loadString(f.sectionsAsset);
        final sectionsJson = json.decode(sectionsRaw) as Map<String, dynamic>;
        sections = (sectionsJson['sections'] as List)
            .cast<Map<String, dynamic>>()
            .map(Section.fromJson)
            .toList();
      }
      // Once a fixture has been edited, a writable copy exists — load that
      // (file-backed, editable) instead of the read-only asset. Until then the
      // asset is the source of truth, so un-edited fixtures track asset updates.
      final editedPath = await _storage.fixtureFilePathIfExists(f.id);
      pieces.add(Piece(
        id: f.id,
        title: f.title,
        musicXmlAssetPath: editedPath == null ? f.scoreAsset : null,
        musicXmlFilePath: editedPath,
        sectionsAssetPath: f.sectionsAsset,
        sections: sections,
      ));
    }
    LaunchTiming.mark('  loadAll: ${bundled.length} bundled');
    final scannedPieces = await _storage.loadScannedPieces();
    LaunchTiming.mark('  loadAll: scanned index (${scannedPieces.length})');
    for (final scanned in scannedPieces) {
      // Scanned pieces carry their sections only as an override sidecar.
      final override = await _storage.loadSectionsOverride(scanned.id);
      pieces.add(override == null
          ? scanned
          : scanned.copyWith(
              sections: override.map(Section.fromJson).toList()));
    }
    return pieces;
  }

  /// Everything the app fixes about a piece's MusicXML, in one place.
  ///
  /// Every pass is gated on evidence the file needs it, so a document that
  /// already says what it means comes back unchanged, character for character.
  /// Applied wherever XML enters or leaves the repository — read it, save it or
  /// edit it and you get the repaired form — which is what keeps a single
  /// convention in force everywhere downstream.
  static String _repair(String musicXml) => MusicXmlBeamer.rebeam(
      MusicXmlNormalizer.drawAccidentals(MusicXmlNormalizer.slursToTies(
          MusicXmlNormalizer.toSoundingPitch(musicXml))));

  /// A piece's MusicXML, repaired: key-signature accidentals resolved into the
  /// sounding pitch, scanned slurs that are really ties made ties, a sign
  /// drawn on every note that needs one, and beams written for any measure
  /// that states none.
  ///
  /// This is the one place every piece's XML is read — bundled fixture or file
  /// — so it is where a tune imported before those passes existed gets fixed. A
  /// file-backed piece is rewritten in place so the migration happens once and
  /// the file on disk stops disagreeing with what the app plays and draws; a
  /// bundled asset is read-only and is repaired in memory (a no-op in practice,
  /// since all of them were already sounding-led and beamed).
  Future<String> loadMusicXml(Piece piece) async {
    final assetPath = piece.musicXmlAssetPath;
    if (assetPath != null) {
      return _repair(await _bundle.loadString(assetPath));
    }
    final filePath = piece.musicXmlFilePath!;
    final raw = await _storage.readScannedMusicXml(filePath);
    final repaired = _repair(raw);
    if (repaired != raw) {
      await updateScannedPiece(filePath, repaired);
    }
    return repaired;
  }

  /// Persists a scanned/imported piece's MusicXML and returns the resulting
  /// [Piece]. Auto-detects the sectional form (AABB/ABAA …) and, when found,
  /// writes it to the piece's override sidecar so the section minimap appears.
  /// Detection is best-effort — a failure or a structureless tune just yields a
  /// piece with empty `sections` (no minimap), exactly as before.
  Future<Piece> savePiece(String title, String musicXml) async {
    // Repair before storing, not on the way back out: the ABC converter leaves
    // key-signature accidentals implicit (see [MusicXmlNormalizer]), and
    // section detection below compares notes by MIDI number, so a drawing-led
    // tune would be sectioned on the wrong pitches.
    final repaired = _repair(musicXml);
    final piece = await _storage.saveScannedPiece(title, repaired);
    try {
      final parsed = MusicXmlParser().parse(repaired);
      final sections = SectionDetector.detect(parsed.measures);
      if (sections.isNotEmpty) {
        await saveSections(piece.id, sections);
        return piece.copyWith(sections: sections);
      }
    } catch (_) {
      // Never block import/scan on section detection.
    }
    return piece;
  }

  /// Runs section detection again over [piece] as it stands now, measure
  /// edits included, and returns what it finds without saving it. Detection
  /// otherwise only runs at import, so this is how an existing piece gets a
  /// better detector. [sourceXml] is the piece re-converted from its stored
  /// ABC source: it carries where the author began each line and part, which
  /// an import before those were kept doesn't have. Never rewrites the XML.
  Future<List<Section>> redetectSections(Piece piece,
      {String? sourceXml}) async {
    var measures = MusicXmlParser().parse(await loadMusicXml(piece)).measures;
    if (sourceXml != null) {
      measures = SectionDetector.withAuthoredHints(
          measures, MusicXmlParser().parse(sourceXml).measures);
    }
    return SectionDetector.detect(measures);
  }

  /// Overwrites a scanned piece's MusicXML file with [newMusicXml] (used by the
  /// measure editor). Mirrors the [savePiece] → `saveScannedPiece` passthrough.
  Future<void> updateScannedPiece(String musicXmlFilePath, String newMusicXml) {
    return _storage.updateScannedPieceFile(musicXmlFilePath, newMusicXml);
  }

  /// Materializes a writable copy of fixture [id] containing [musicXml] and
  /// returns its file path. Used the first time a bundled fixture is edited, so
  /// it becomes file-backed and editable thereafter.
  Future<String> createEditableFixtureFile(String id, String musicXml) {
    return _storage.writeFixtureFile(id, musicXml);
  }

  /// Writes [newMusicXml] as [piece]'s content and returns the piece to select
  /// afterwards. A file-backed piece (a scan, or a previously-edited fixture) is
  /// overwritten in place; the first edit of a bundled fixture materializes a
  /// writable copy, so the returned piece is file-backed and stays editable.
  /// Shared by every editing entry point (measure editor, measure delete), so
  /// it is where [_repair] runs on the way out: a measure the editor rebuilt
  /// states no beams, and gets them here rather than leaving the editor to know
  /// what a beam is.
  Future<Piece> writeEditedMusicXml(Piece piece, String newMusicXml) async {
    final repaired = _repair(newMusicXml);
    if (piece.musicXmlFilePath != null) {
      await updateScannedPiece(piece.musicXmlFilePath!, repaired);
      return piece;
    }
    final filePath = await createEditableFixtureFile(piece.id, repaired);
    return piece.backedByFile(filePath);
  }

  /// Permanently removes a user-added piece and every artifact keyed to its id:
  /// its MusicXML, its index row (io) / prefs keys (web), its section-override
  /// sidecar, and any editable copy it accumulated. Idempotent.
  ///
  /// NOT for bundled fixtures — their MusicXML ships inside the app bundle and
  /// cannot be removed, so the library hides them instead. Callers must check
  /// [isBundled] first; this asserts it.
  ///
  /// Deliberately does not touch the staff-zoom preference or the piece
  /// library: both stores bypass this class by design. `LibraryActions` in
  /// `providers.dart` is where the full delete is composed.
  Future<void> deletePiece(String id) async {
    assert(!isBundled(id), 'Bundled fixtures are hidden, never deleted');
    await _storage.deleteScannedPiece(id);
    await _storage.deleteSectionsOverride(id);
    await _storage.deleteFixtureFile(id);
  }

  /// Persists [sections] (section start markers) to piece [id]'s override
  /// sidecar. Applies to both fixtures and scanned pieces; `loadAll` then
  /// prefers this over any bundled section asset.
  Future<void> saveSections(String id, List<Section> sections) {
    return _storage.saveSectionsOverride(id, [for (final s in sections) s.toJson()]);
  }
}

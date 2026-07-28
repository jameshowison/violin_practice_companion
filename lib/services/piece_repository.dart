import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/piece.dart';
import '../models/section.dart';
import 'musicxml_parser.dart';
import 'piece_storage.dart';
import 'section_detector.dart';

class PieceRepository {
  static const _fixtures = [
    (
      id: 'lightly_row',
      title: 'Lightly Row',
      xml: 'assets/fixtures/lightly_row_musescore.xml',
      sections: 'assets/fixtures/sections/lightly_row_sections.json',
    ),
    (
      id: 'happy_farmer',
      title: 'The Happy Farmer, Op.68 No.10',
      xml: 'assets/fixtures/happy_farmer_musescore.xml',
      sections: 'assets/fixtures/sections/happy_farmer_musescore_sections.json',
    ),
    (
      id: 'gossec_gavotte',
      title: 'Gavotte (Gossec)',
      xml: 'assets/fixtures/gossec_gavotte.xml',
      sections: 'assets/fixtures/sections/gossec_gavotte_sections.json',
    ),
    // OMR comparison pairs: abc (ground truth) then homr (engine output)
    (
      id: 'abc_05_o_come_little_children',
      title: '05 O Come Little Children (abc)',
      xml: 'assets/fixtures/abc_05_o_come_little_children.xml',
      sections: 'assets/fixtures/sections/abc_05_sections.json',
    ),
    (
      id: 'homr_05_o_come_little_children',
      title: '05 O Come Little Children (homr)',
      xml: 'assets/fixtures/homr_05_o_come_little_children.xml',
      sections: 'assets/fixtures/sections/homr_05_sections.json',
    ),
    (
      id: 'abc_10_allegretto',
      title: '10 Allegretto (abc)',
      xml: 'assets/fixtures/abc_10_allegretto.xml',
      sections: 'assets/fixtures/sections/abc_10_sections.json',
    ),
    (
      id: 'homr_10_allegretto',
      title: '10 Allegretto (homr)',
      xml: 'assets/fixtures/homr_10_allegretto.xml',
      sections: 'assets/fixtures/sections/homr_10_sections.json',
    ),
    (
      id: 'abc_14_minuet_no_2',
      title: '14 Minuet No. 2 (abc)',
      xml: 'assets/fixtures/abc_14_minuet_no_2.xml',
      sections: 'assets/fixtures/sections/abc_14_sections.json',
    ),
    (
      id: 'homr_14_minuet_no_2',
      title: '14 Minuet No. 2 (homr)',
      xml: 'assets/fixtures/homr_14_minuet_no_2.xml',
      sections: 'assets/fixtures/sections/homr_14_sections.json',
    ),
    (
      id: 'abc_15_minuet_no_3',
      title: '15 Minuet No. 3 (abc)',
      xml: 'assets/fixtures/abc_15_minuet_no_3.xml',
      sections: 'assets/fixtures/sections/abc_15_sections.json',
    ),
    (
      id: 'homr_15_minuet_no_3',
      title: '15 Minuet No. 3 (homr)',
      xml: 'assets/fixtures/homr_15_minuet_no_3.xml',
      sections: 'assets/fixtures/sections/homr_15_sections.json',
    ),
    (
      id: 'abc_17_gavotte',
      title: '17 Gavotte (abc)',
      xml: 'assets/fixtures/abc_17_gavotte.xml',
      sections: 'assets/fixtures/sections/abc_17_sections.json',
    ),
    (
      id: 'homr_17_gavotte',
      title: '17 Gavotte (homr)',
      xml: 'assets/fixtures/homr_17_gavotte.xml',
      sections: 'assets/fixtures/sections/homr_17_sections.json',
    ),
  ];

  /// Whether the current platform supports editing (writable file storage).
  bool get supportsEditing => storageSupportsEditing;

  Future<List<Piece>> loadAll() async {
    final pieces = <Piece>[];
    for (final f in _fixtures) {
      // Prefer an edited section override (sidecar) over the bundled asset, so
      // section edits persist; un-edited fixtures track the bundled asset.
      final override = await loadSectionsOverride(f.id);
      final List<Section> sections;
      if (override != null) {
        sections = override.map(Section.fromJson).toList();
      } else {
        final sectionsRaw = await rootBundle.loadString(f.sections);
        final sectionsJson = json.decode(sectionsRaw) as Map<String, dynamic>;
        sections = (sectionsJson['sections'] as List)
            .cast<Map<String, dynamic>>()
            .map(Section.fromJson)
            .toList();
      }
      // Once a fixture has been edited, a writable copy exists — load that
      // (file-backed, editable) instead of the read-only asset. Until then the
      // asset is the source of truth, so un-edited fixtures track asset updates.
      final editedPath = await fixtureFilePathIfExists(f.id);
      pieces.add(Piece(
        id: f.id,
        title: f.title,
        musicXmlAssetPath: editedPath == null ? f.xml : null,
        musicXmlFilePath: editedPath,
        sectionsAssetPath: f.sections,
        sections: sections,
      ));
    }
    for (final scanned in await loadScannedPieces()) {
      // Scanned pieces carry their sections only as an override sidecar.
      final override = await loadSectionsOverride(scanned.id);
      pieces.add(override == null
          ? scanned
          : scanned.copyWith(
              sections: override.map(Section.fromJson).toList()));
    }
    return pieces;
  }

  Future<String> loadMusicXml(Piece piece) async {
    final assetPath = piece.musicXmlAssetPath;
    if (assetPath != null) return rootBundle.loadString(assetPath);
    return readScannedMusicXml(piece.musicXmlFilePath!);
  }

  /// Persists a scanned/imported piece's MusicXML and returns the resulting
  /// [Piece]. Auto-detects the sectional form (AABB/ABAA …) and, when found,
  /// writes it to the piece's override sidecar so the section minimap appears.
  /// Detection is best-effort — a failure or a structureless tune just yields a
  /// piece with empty `sections` (no minimap), exactly as before.
  Future<Piece> savePiece(String title, String musicXml) async {
    final piece = await saveScannedPiece(title, musicXml);
    try {
      final parsed = MusicXmlParser().parse(musicXml);
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

  /// Overwrites a scanned piece's MusicXML file with [newMusicXml] (used by the
  /// measure editor). Mirrors the [savePiece] → `saveScannedPiece` passthrough.
  Future<void> updateScannedPiece(String musicXmlFilePath, String newMusicXml) {
    return updateScannedPieceFile(musicXmlFilePath, newMusicXml);
  }

  /// Materializes a writable copy of fixture [id] containing [musicXml] and
  /// returns its file path. Used the first time a bundled fixture is edited, so
  /// it becomes file-backed and editable thereafter.
  Future<String> createEditableFixtureFile(String id, String musicXml) {
    return writeFixtureFile(id, musicXml);
  }

  /// Persists [sections] (section start markers) to piece [id]'s override
  /// sidecar. Applies to both fixtures and scanned pieces; `loadAll` then
  /// prefers this over any bundled section asset.
  Future<void> saveSections(String id, List<Section> sections) {
    return saveSectionsOverride(id, [for (final s in sections) s.toJson()]);
  }
}

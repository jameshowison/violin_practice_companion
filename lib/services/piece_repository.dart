import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/piece.dart';
import '../models/section.dart';

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
  ];

  Future<List<Piece>> loadAll() async {
    final pieces = <Piece>[];
    for (final f in _fixtures) {
      final sectionsRaw = await rootBundle.loadString(f.sections);
      final sectionsJson = json.decode(sectionsRaw) as Map<String, dynamic>;
      final sections = (sectionsJson['sections'] as List)
          .cast<Map<String, dynamic>>()
          .map(Section.fromJson)
          .toList();
      pieces.add(Piece(
        id: f.id,
        title: f.title,
        musicXmlAssetPath: f.xml,
        sectionsAssetPath: f.sections,
        sections: sections,
      ));
    }
    return pieces;
  }

  Future<String> loadMusicXml(Piece piece) async {
    return rootBundle.loadString(piece.musicXmlAssetPath);
  }
}

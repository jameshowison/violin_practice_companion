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

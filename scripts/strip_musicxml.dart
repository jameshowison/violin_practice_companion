/// Writes fully-processed MusicXML to assets/striped/ — identical to what
/// the app passes to OSMD in staff mode:
///   1. Load raw XML
///   2. stripLayoutHints() — strips print/spacing elements so OSMD lays out its own systems
///   3. stripFingerings()
///
/// Layout is computed at 2 measures per row (phone landscape default).
///
/// Usage (from project root):
///   dart run scripts/strip_musicxml.dart
library;

import 'dart:convert';
import 'dart:io';

import '../lib/models/section.dart';
import '../lib/models/piece_layout.dart';
import '../lib/services/musicxml_parser.dart';
import '../lib/services/fingering_xml_injector.dart';

const _fixtures = [
  (
    xml: 'assets/fixtures/lightly_row_musescore.xml',
    sections: 'assets/fixtures/sections/lightly_row_sections.json',
  ),
  (
    xml: 'assets/fixtures/happy_farmer_musescore.xml',
    sections: 'assets/fixtures/sections/happy_farmer_musescore_sections.json',
  ),
  (
    xml: 'assets/fixtures/gossec_gavotte.xml',
    sections: 'assets/fixtures/sections/gossec_gavotte_sections.json',
  ),
];

void main() {
  final parser = MusicXmlParser();

  final outDir = Directory('assets/striped');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  for (final f in _fixtures) {
    final rawXml = File(f.xml).readAsStringSync();

    final sectionsJson =
        json.decode(File(f.sections).readAsStringSync()) as Map<String, dynamic>;
    final sections = (sectionsJson['sections'] as List)
        .cast<Map<String, dynamic>>()
        .map(Section.fromJson)
        .toList();

    final parsed = parser.parse(rawXml);
    final layout = PieceLayout.compute(
      parsed.measures,
      sections,
      measuresPerRow: 2,
    );

    var xml = layout.stripLayoutHints(rawXml);
    xml = FingeringXmlInjector.stripFingerings(xml);

    final outName = f.xml.split('/').last;
    File('assets/striped/$outName').writeAsStringSync(xml);
    print('Wrote assets/striped/$outName '
        '(${layout.rows.length} rows, ${layout.measureCount} measures)');
  }
}

import 'package:xml/xml.dart';

/// Controls whether MusicXML `<harmony>` (chord symbols) reach Verovio.
///
/// The source MusicXML carries `<harmony>` elements, which Verovio's importer
/// maps to `<harm>` and engraves as chord symbols above the staff — no MEI or
/// overlay needed (verified: `verovio_flutter` bundles Verovio 6.2). Showing
/// chords is therefore just "leave the harmony in"; hiding them is
/// [stripHarmony]. Mirrors `FingeringXmlInjector.stripFingerings`.
class ChordXmlInjector {
  /// Removes every `<harmony>` element so no chord symbols are engraved.
  static String stripHarmony(String musicXml) {
    final doc = XmlDocument.parse(musicXml);
    for (final h in doc.findAllElements('harmony').toList()) {
      h.parent?.children.remove(h);
    }
    return doc.toXmlString();
  }
}

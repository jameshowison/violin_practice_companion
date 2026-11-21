import 'package:xml/xml.dart';

import 'measure_xml_editor.dart';

/// Makes a scanned bar of whole rest a whole-BAR rest.
///
/// In print, a whole-rest glyph alone in a bar means "rest for the whole bar"
/// in any meter: in 2/4 it lasts two beats, in 3/4 three. The recogniser reads
/// the glyph correctly but writes it as a whole note's worth of rest, four
/// beats, so every such bar in a 2/4 piece came out twice as long as its
/// neighbours. On a 56-bar 2/4 scan that was eight bars, three of them in a
/// row, which is also enough for [MeterRepair] to believe a change to 4/4.
///
/// [mark] runs before [MeterRepair], so that a bar rest is no evidence for a
/// meter (it is as long as whatever meter governs it); [fit] runs after, and
/// gives each bar rest the `<duration>` of the meter it ended up in.
class BarRestRepair {
  /// [musicXml] with every bar whose only content is one whole rest turned
  /// into `<rest measure="yes"/>`; unchanged if there were none, or it doesn't
  /// parse.
  static String mark(String musicXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } on XmlException {
      return musicXml;
    }
    var changed = false;
    for (final measure in doc.findAllElements('measure')) {
      if (measure.findElements('backup').isNotEmpty ||
          measure.findElements('forward').isNotEmpty) {
        continue;
      }
      final notes = measure.findElements('note').toList();
      if (notes.length != 1) continue;
      final rest = notes.single.getElement('rest');
      if (rest == null || rest.getAttribute('measure') == 'yes') continue;
      if (notes.single.getElement('type')?.innerText.trim() != 'whole') {
        continue;
      }
      if (notes.single.findElements('dot').isNotEmpty) continue;
      rest.setAttribute('measure', 'yes');
      changed = true;
    }
    return changed ? doc.toXmlString() : musicXml;
  }

  /// [musicXml] with each whole-bar rest's `<duration>` set to the length of
  /// the meter in force; unchanged if there are none, or it doesn't parse.
  static String fit(String musicXml) {
    if (!musicXml.contains('measure="yes"')) return musicXml;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } on XmlException {
      return musicXml;
    }
    doc.findAllElements('part').forEach(MeasureXmlEditor.fitBarRests);
    return doc.toXmlString();
  }
}

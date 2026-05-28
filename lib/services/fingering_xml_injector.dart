import 'package:xml/xml.dart';
import '../models/parsed_piece.dart';
import '../models/string_label_style.dart';

class FingeringXmlInjector {
  static String inject(String musicXml, ParsedPiece parsed, StringLabelStyle style) {
    final doc = XmlDocument.parse(musicXml);
    final noteEvents = parsed.measures.expand((m) => m.notes).toList();

    int idx = 0;
    String? prevString;
    for (final noteEl in doc.findAllElements('note')) {
      if (noteEl.getAttribute('print-object') == 'no') continue;
      if (idx >= noteEvents.length) break;
      final ne = noteEvents[idx++];

      if (ne.isRest || ne.fingerString == null || ne.fingerNumber == null) continue;

      final strPart = switch (style) {
        StringLabelStyle.always   => ne.fingerString!,
        StringLabelStyle.onChange => ne.fingerString != prevString ? ne.fingerString! : '',
        StringLabelStyle.never    => '',
      };
      final label = '$strPart${ne.fingerNumber}';
      prevString = ne.fingerString;

      _setFingering(noteEl, label);
    }

    return doc.toXmlString();
  }

  static void _setFingering(XmlElement noteEl, String label) {
    var notations = noteEl.findElements('notations').firstOrNull;
    if (notations == null) {
      notations = XmlElement(XmlName('notations'));
      noteEl.children.add(notations);
    }
    var technical = notations.findElements('technical').firstOrNull;
    if (technical == null) {
      technical = XmlElement(XmlName('technical'));
      notations.children.add(technical);
    }
    final existing = technical.findElements('fingering').firstOrNull;
    if (existing != null) {
      existing.children
        ..clear()
        ..add(XmlText(label));
    } else {
      technical.children.add(
        XmlElement(XmlName('fingering'), [], [XmlText(label)]),
      );
    }
  }
}

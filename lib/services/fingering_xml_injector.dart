import 'package:xml/xml.dart';
import '../models/parsed_piece.dart';
import '../models/string_label_style.dart';

class FingeringXmlInjector {
  static String inject(
    String musicXml,
    ParsedPiece parsed,
    StringLabelStyle style,
  ) {
    final doc = XmlDocument.parse(musicXml);
    final noteEvents = parsed.measures.expand((m) => m.notes).toList();

    int idx = 0;
    String? prevString;
    for (final noteEl in doc.findAllElements('note')) {
      if (noteEl.getAttribute('print-object') == 'no') continue;
      if (idx >= noteEvents.length) break;
      final ne = noteEvents[idx++];

      if (ne.isRest || ne.fingerString == null || ne.fingerNumber == null)
        continue;

      final strPart = switch (style) {
        StringLabelStyle.always => ne.fingerString!,
        StringLabelStyle.onChange =>
          ne.fingerString != prevString ? ne.fingerString! : '',
        StringLabelStyle.never => '',
      };
      final label = '$strPart${ne.fingerNumber}';
      prevString = ne.fingerString;

      _setFingering(noteEl, label);
    }

    return doc.toXmlString();
  }

  /// Injects a fixed placeholder `<fingering>` on every note that HAS a
  /// fingering, regardless of what the app will actually draw there.
  ///
  /// For the native renderer, where the engraved glyph is hidden and the app
  /// paints its own chip. The engraved element exists only so Verovio RESERVES
  /// the row: it lays the fingering out as real content, grows the page to fit
  /// it, and reports where it put it — which is the one thing the app cannot
  /// work out for itself. See `AnnotationAnchor`.
  ///
  /// Deliberately independent of [StringLabelStyle], the fingering density and
  /// the note-number mode. Those all change what the chip SAYS, never whether a
  /// note has one, so making the engraved text follow them would put the page
  /// layout — and therefore the reflow — behind a display toggle. A single
  /// character on every fingered note keeps the reserved row uniform and the
  /// layout stable no matter what the user switches.
  ///
  /// The cost is that a label wider than the placeholder can overrun its
  /// neighbour horizontally; the chip painter's left-to-right overlap guard
  /// already drops those, which is the same thing it has always done.
  static String injectPlaceholders(String musicXml, ParsedPiece parsed) {
    final doc = XmlDocument.parse(musicXml);
    final noteEvents = parsed.measures.expand((m) => m.notes).toList();
    int idx = 0;
    for (final noteEl in doc.findAllElements('note')) {
      if (noteEl.getAttribute('print-object') == 'no') continue;
      if (idx >= noteEvents.length) break;
      final ne = noteEvents[idx++];
      if (ne.isRest || ne.fingerString == null || ne.fingerNumber == null) {
        continue;
      }
      _setFingering(noteEl, placeholderLabel);
    }
    return doc.toXmlString();
  }

  /// The reserver's text. One digit: Verovio's own fingering glyphs are all
  /// single characters, so this asks for exactly the row height a real engraving
  /// would need, and no more.
  static const placeholderLabel = '0';

  static String stripFingerings(String musicXml) {
    final doc = XmlDocument.parse(musicXml);
    for (final technical in doc.findAllElements('technical').toList()) {
      for (final f in technical.findElements('fingering').toList()) {
        technical.children.remove(f);
      }
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

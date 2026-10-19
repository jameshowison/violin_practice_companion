import 'package:xml/xml.dart';

/// Builds a minimal one-measure MusicXML carrying only the piece's opening
/// clef, key, and time signature — no real notes — for a small standalone
/// engrave shown next to the piece title in the app bar.
///
/// Pairs with `hideFirstSystemPreamble` (`system_break_injector.dart`), which
/// strips this same preamble out of the main render so its space goes to
/// notes instead. Reads the FIRST measure of the UNTOUCHED piece XML — call
/// this before that stripping runs, or against a separate copy.
///
/// The one whole-measure rest is marked `print-object="no"` so Verovio has a
/// well-formed measure to lay out without drawing, or reserving space for, a
/// note. Confirmed headlessly against the bundled wasm toolkit: an invisible
/// rest and no note at all produced the identical tight auto-cropped viewBox
/// (435×258 at scale 100), while a visible rest widened it to 467×258.
String buildPreambleXml(String musicXml) {
  final firstMeasure =
      XmlDocument.parse(musicXml).findAllElements('measure').first;
  // Merged, not just the first block: a scanned (OMR) piece can open with a
  // divisions-only `<attributes>` and put key/time/clef in a second one, and
  // reading only the first engraved a bare five-line staff.
  final attributes = XmlElement(XmlName.parts('attributes'), [], [
    for (final block in firstMeasure.findElements('attributes'))
      for (final child in block.childElements) child.copy(),
  ]);

  final divisions = int.tryParse(
        attributes.findElements('divisions').firstOrNull?.innerText ?? '',
      ) ??
      1;
  final beats = int.tryParse(
        attributes
                .findElements('time')
                .firstOrNull
                ?.findElements('beats')
                .firstOrNull
                ?.innerText ??
            '',
      ) ??
      4;

  final rest = XmlElement(
    XmlName.parts('note'),
    [XmlAttribute(XmlName.parts('print-object'), 'no')],
    [
      XmlElement(XmlName.parts('rest')),
      XmlElement(XmlName.parts('duration'), [], [XmlText('${divisions * beats}')]),
    ],
  );

  // No closing barline: it would only add a stroke, and space before it, past
  // the time signature that is the preview's last glyph.
  final barline = XmlElement(
    XmlName.parts('barline'),
    [XmlAttribute(XmlName.parts('location'), 'right')],
    [XmlElement(XmlName.parts('bar-style'), [], [XmlText('none')])],
  );

  final measure = XmlElement(
    XmlName.parts('measure'),
    [XmlAttribute(XmlName.parts('number'), '1')],
    [attributes, rest, barline],
  );

  final part = XmlElement(
    XmlName.parts('part'),
    [XmlAttribute(XmlName.parts('id'), 'P1')],
    [measure],
  );

  final partList = XmlElement(XmlName.parts('part-list'), [], [
    XmlElement(XmlName.parts('score-part'), [XmlAttribute(XmlName.parts('id'), 'P1')], [
      XmlElement(XmlName.parts('part-name'), [], [XmlText('Music')]),
    ]),
  ]);

  final root = XmlElement(
    XmlName.parts('score-partwise'),
    [XmlAttribute(XmlName.parts('version'), '4.0')],
    [partList, part],
  );

  return XmlDocument([
    XmlProcessing('xml', 'version="1.0" encoding="UTF-8"'),
    root,
  ]).toXmlString();
}

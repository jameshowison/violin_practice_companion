import 'package:xml/xml.dart';

/// The system-break mechanics every break pass shares: a `<print
/// new-system="yes">` before a measure, plus the clef/time Verovio would
/// auto-repeat there stated with `print-object="no"`, so Verovio doesn't
/// reserve room for them (see `insertSystemBreaks` in the app's
/// `system_break_injector.dart` for why that matters).
///
/// [insertBreaksAtPositions] and [systemStartPositions] are what the section
/// layout (`section_engraving.dart`) needs. [AttrState], [insertPrintBreak]
/// and [hidePreamble] are public for the app's other break passes.

/// Inserts a system break before each measure at a document POSITION in
/// [positions] (0-based, per part; position 0 is ignored) — for a layout
/// whose break points were planned against the engraved measures, where a
/// split bar's slices have no plain number to name them by. Same mechanics
/// as every other break here: `<print new-system>` plus the hidden clef/time.
String insertBreaksAtPositions(String musicXml, Set<int> positions) {
  if (positions.isEmpty) return musicXml;
  final doc = XmlDocument.parse(musicXml);
  for (final part in doc.findAllElements('part')) {
    final measures = part.findElements('measure').toList();
    final state = AttrState();
    for (var i = 0; i < measures.length; i++) {
      state.update(measures[i]);
      if (i == 0 || !positions.contains(i)) continue;
      if (_hasSystemBreak(measures[i])) continue;
      insertPrintBreak(measures[i]);
      hidePreamble(measures[i], state);
    }
  }
  return doc.toXmlString();
}

/// Document positions of the first part's measures that open a system: 0,
/// then every measure carrying `<print new-system="yes">`.
List<int> systemStartPositions(String musicXml) {
  final doc = XmlDocument.parse(musicXml);
  final part = doc.findAllElements('part').firstOrNull;
  if (part == null) return const [];
  final measures = part.findElements('measure').toList();
  return [
    for (var i = 0; i < measures.length; i++)
      if (i == 0 || _hasSystemBreak(measures[i])) i,
  ];
}

bool _hasSystemBreak(XmlElement measure) => measure
    .findElements('print')
    .any((p) => p.getAttribute('new-system') == 'yes');

/// The clef/time/divisions in effect at whatever measure was last [update]d —
/// MusicXML only restates `<attributes>` on change, so this tracks the
/// running "current" values every break pass needs, either to decide if a
/// measure is a pickup ([isPickup]) or to know what a hidden preamble should
/// carry. Key signature isn't tracked: [hidePreamble] leaves it to Verovio's
/// own auto-repeat rather than restating it.
class AttrState {
  var divisions = 1;
  var beats = 4;
  var beatType = 4;
  var clefSign = 'G';
  var clefLine = 2;

  void update(XmlElement measure) {
    // A measure may carry more than one `<attributes>` (scanned pieces split
    // divisions from clef/key/time), and each block can change the state.
    for (final attributes in measure.findElements('attributes')) {
      _apply(attributes);
    }
  }

  void _apply(XmlElement attributes) {
    final d = attributes.findElements('divisions').firstOrNull;
    if (d != null) divisions = int.tryParse(d.innerText) ?? divisions;
    final time = attributes.findElements('time').firstOrNull;
    final b = time?.findElements('beats').firstOrNull;
    final bt = time?.findElements('beat-type').firstOrNull;
    if (b != null) beats = int.tryParse(b.innerText) ?? beats;
    if (bt != null) beatType = int.tryParse(bt.innerText) ?? beatType;
    final clef = attributes.findElements('clef').firstOrNull;
    final sign = clef?.findElements('sign').firstOrNull;
    final line = clef?.findElements('line').firstOrNull;
    if (sign != null) clefSign = sign.innerText;
    if (line != null) clefLine = int.tryParse(line.innerText) ?? clefLine;
  }

  bool isPickup(XmlElement measure) =>
      _measureDuration(measure) < divisions * beats * 4 / beatType;
}

/// Sum of this measure's sounding note/rest durations — chord members and
/// grace notes excluded, since neither advances the measure's time cursor.
num _measureDuration(XmlElement measure) {
  num total = 0;
  for (final note in measure.findElements('note')) {
    if (note.findElements('chord').isNotEmpty) continue;
    if (note.findElements('grace').isNotEmpty) continue;
    final duration = note.findElements('duration').firstOrNull;
    if (duration == null) continue;
    total += num.tryParse(duration.innerText) ?? 0;
  }
  return total;
}

/// A leading `<print>` belongs at the very start of the measure — same
/// adjacency check as `MeasureXmlEditor._addRepeat`'s left barline insertion.
/// In practice there won't be one (this runs after
/// `PieceLayout.stripLayoutHints`), but match the established defensive
/// pattern rather than assume.
void insertPrintBreak(XmlElement measure) {
  final printBreak = XmlElement(
    XmlName.parts('print'),
    [XmlAttribute(XmlName.parts('new-system'), 'yes')],
  );
  final printIdx = measure.children
      .indexWhere((n) => n is XmlElement && n.name.local == 'print');
  measure.children.insert(printIdx == -1 ? 0 : printIdx + 1, printBreak);
}

/// MusicXML `<attributes>` child order relevant here — `key`/`time` precede
/// `clef` (see the fuller list `MeasureXmlEditor._attrOrder` maintains for the
/// same reason).
const _attrOrder = ['divisions', 'key', 'time', 'staves', 'part-symbol', 'instruments', 'clef'];

int _attrRank(XmlElement e) {
  final i = _attrOrder.indexOf(e.name.local);
  return i < 0 ? _attrOrder.length : i;
}

/// Hides the clef/time Verovio would otherwise auto-repeat at [measure] (a
/// system-start), by stating them explicitly with `print-object="no"` — but
/// only whichever of the two [measure]'s own `<attributes>` doesn't already
/// carry (a genuine change there stays visible). Reuses any existing
/// `<attributes>` block rather than adding a second one, re-sorting into
/// schema order same as `MeasureXmlEditor._carryAttributes`.
///
/// The key signature is left out of this treatment on purpose — see the
/// app's `hideFirstSystemPreamble` for why — so Verovio just auto-repeats it
/// normally at every system, same as standard engraving.
void hidePreamble(XmlElement measure, AttrState state) {
  // Whether the measure already states a clef/time is a question about ALL
  // its blocks — a scanned piece can carry them in a second one.
  bool states(String name) => measure
      .findElements('attributes')
      .any((a) => a.findElements(name).isNotEmpty);
  final hasClef = states('clef');
  final hasTime = states('time');

  var attributes = measure.findElements('attributes').firstOrNull;
  final isNewBlock = attributes == null;
  attributes ??= XmlElement(XmlName.parts('attributes'));

  if (!hasClef) {
    attributes.children.add(_hiddenElement('clef', [
      XmlElement(XmlName.parts('sign'), [], [XmlText(state.clefSign)]),
      XmlElement(XmlName.parts('line'), [], [XmlText('${state.clefLine}')]),
    ]));
  }
  if (!hasTime) {
    attributes.children.add(_hiddenElement('time', [
      XmlElement(XmlName.parts('beats'), [], [XmlText('${state.beats}')]),
      XmlElement(XmlName.parts('beat-type'), [], [XmlText('${state.beatType}')]),
    ]));
  }

  final ordered = attributes.childElements.map((e) => e.copy()).toList()
    ..sort((a, b) => _attrRank(a).compareTo(_attrRank(b)));
  attributes.children
    ..clear()
    ..addAll(ordered);

  if (isNewBlock) {
    final printIdx = measure.children
        .indexWhere((n) => n is XmlElement && n.name.local == 'print');
    measure.children.insert(printIdx == -1 ? 0 : printIdx + 1, attributes);
  }
}

XmlElement _hiddenElement(String name, List<XmlElement> children) =>
    XmlElement(XmlName.parts(name), [XmlAttribute(XmlName.parts('print-object'), 'no')],
        children);

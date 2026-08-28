import 'package:xml/xml.dart';

import '../models/section.dart';

/// Inserts explicit MusicXML system breaks so Verovio can be told to honor
/// them (`breaks: 'encoded'`) instead of choosing its own — the mechanism
/// behind a guaranteed-exact "lock to N measures per line", as opposed to the
/// approximate `scale`-solving `measuresPerLineProvider` normally drives.
///
/// Sibling to `measure_xml_editor.dart` / `piece_layout.dart` (same
/// parse/mutate/`toXmlString()` shape).
///
/// Two kinds of break, walked per `<part>` by DOCUMENT POSITION (not the
/// numeric `number` attribute — see below):
///  * Section-forced: always breaks before a measure whose `number` matches a
///    [Section.startMeasure], so every section starts its own line.
///  * Budget-forced: within a section (or for a piece with no sections at
///    all), breaks after every [measuresPerLine] measures, same as a plain
///    tiling.
///
/// A measure is a PICKUP — rides free of the per-line budget and never
/// itself opens a line on its own — when its actual note duration is short of
/// a full bar, per the current `<divisions>`/`<time>`, not by trusting
/// MusicXML's `implicit="yes"` flag (which an importer may only set on the
/// piece's very first measure). This matters because a pickup can recur
/// anywhere a repeated strain restarts: Old Joe Clark's section B opens at
/// measure 10 with a single quarter note in a 4/4 bar — exactly pickup-shaped
/// — but isn't flagged `implicit`. Its closing measure 18 is the standard
/// complementary case: a dotted half (3 of the 4 beats the opening pickup at
/// measure 10 borrowed), the usual convention for a repeated strain's final
/// bar. Both are detected the same way, wherever they occur.
///
/// A pickup never stands alone on a line: a budget-triggered break
/// (`count >= measuresPerLine`) is deferred past a pickup measure to the next
/// one, so the pickup joins the tail of the still-open line. A section-forced
/// break is different — it always fires, since there is no earlier line for a
/// section-starting pickup to join (mirrors how the piece's own opening
/// pickup already behaves).
///
/// Every break also hides the clef/key/time Verovio would otherwise
/// auto-repeat at the new system (`<clef print-object="no">` etc., carrying
/// the current inherited values), UNLESS this measure already states its own
/// (a genuine change, which should stay visible). This is not cosmetic:
/// Verovio only skips RESERVING the horizontal space for a repeated
/// clef/key/time when it's marked non-printing before layout runs — engraving
/// normally and stripping the glyph out of the rendered SVG afterward (see
/// `VerovioEngraver.clefKeySigFirstSystemOnly`) leaves the space reserved and
/// empty, a fixed dead margin on every continuation line. Confirmed headlessly
/// against the bundled wasm toolkit: hiding at the source moved a system's
/// first note from x=1324 to x=180 versus letting Verovio auto-repeat and
/// deleting the glyph after the fact.
///
/// Single-voice only — sums top-level `<note><duration>` (skipping chord
/// members and grace notes), no `<backup>`/`<forward>` handling — matching
/// the established assumption in `measure_xml_editor.dart`.
String insertSystemBreaks(
  String musicXml, {
  required int measuresPerLine,
  required List<Section> sections,
}) {
  final sectionStarts = {for (final s in sections) s.startMeasure};
  final doc = XmlDocument.parse(musicXml);

  for (final part in doc.findAllElements('part')) {
    final measures = part.findElements('measure').toList();
    final state = _AttrState();
    var count = 0; // real (non-pickup) measures placed on the current line
    var pendingBreak = false; // budget hit while sitting on a pickup

    for (var i = 0; i < measures.length; i++) {
      final measure = measures[i];
      state.update(measure);
      final isPickup = state.isPickup(measure);

      if (i == 0) {
        // Never break before the piece's own first measure.
        if (!isPickup) count++;
        continue;
      }

      final number = int.tryParse(measure.getAttribute('number') ?? '');
      final isSectionStart = number != null && sectionStarts.contains(number);
      final atBudget = count >= measuresPerLine || pendingBreak;

      if (isSectionStart || (atBudget && !isPickup)) {
        _insertPrintBreak(measure);
        _hidePreamble(measure, state);
        count = 0;
        pendingBreak = false;
      } else if (atBudget && isPickup) {
        pendingBreak = true; // don't isolate the pickup; break at the next
      }

      if (!isPickup) count++;
    }
  }

  return doc.toXmlString();
}

/// Freezes system breaks Verovio's own `breaks: 'auto'` layout already chose
/// — [breakMeasureNumbers], each the first measure of a system after the
/// first — into explicit `<print new-system="yes"/>` markers, with the same
/// hidden-preamble treatment [insertSystemBreaks] applies at its own break
/// points. Auto mode's counterpart: the break POSITIONS come from what
/// Verovio already decided (read off the engraved `measureLine`), not from a
/// measures-per-line target — this only recovers the dead margin
/// `VerovioEngraver.clefKeySigFirstSystemOnly` otherwise leaves on every
/// continuation line; it doesn't change which measures share a line.
String freezeSystemBreaks(String musicXml, Set<int> breakMeasureNumbers) {
  final doc = XmlDocument.parse(musicXml);

  for (final part in doc.findAllElements('part')) {
    final measures = part.findElements('measure').toList();
    final state = _AttrState();

    for (var i = 0; i < measures.length; i++) {
      final measure = measures[i];
      state.update(measure);
      if (i == 0) continue;

      final number = int.tryParse(measure.getAttribute('number') ?? '');
      if (number == null || !breakMeasureNumbers.contains(number)) continue;

      _insertPrintBreak(measure);
      _hidePreamble(measure, state);
    }
  }

  return doc.toXmlString();
}

/// The clef/key/time/divisions in effect at whatever measure was last
/// [update]d — MusicXML only restates `<attributes>` on change, so this
/// tracks the running "current" values both break functions need, either to
/// decide if a measure is a pickup ([isPickup]) or to know what a hidden
/// preamble should carry.
class _AttrState {
  var divisions = 1;
  var beats = 4;
  var beatType = 4;
  var clefSign = 'G';
  var clefLine = 2;
  var keyFifths = 0;

  void update(XmlElement measure) {
    final attributes = measure.findElements('attributes').firstOrNull;
    if (attributes == null) return;
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
    final key = attributes.findElements('key').firstOrNull;
    final fifths = key?.findElements('fifths').firstOrNull;
    if (fifths != null) keyFifths = int.tryParse(fifths.innerText) ?? keyFifths;
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
void _insertPrintBreak(XmlElement measure) {
  final printBreak = XmlElement(
    XmlName('print'),
    [XmlAttribute(XmlName('new-system'), 'yes')],
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

/// Hides the clef/key/time Verovio would otherwise auto-repeat at [measure]
/// (a system-start), by stating them explicitly with `print-object="no"` —
/// but only whichever of the three [measure]'s own `<attributes>` doesn't
/// already carry (a genuine change there stays visible). Reuses any existing
/// `<attributes>` block rather than adding a second one, re-sorting into
/// schema order same as `MeasureXmlEditor._carryAttributes`.
void _hidePreamble(XmlElement measure, _AttrState state) {
  var attributes = measure.findElements('attributes').firstOrNull;
  final isNewBlock = attributes == null;
  attributes ??= XmlElement(XmlName('attributes'));

  if (attributes.findElements('clef').isEmpty) {
    attributes.children.add(_hiddenElement('clef', [
      XmlElement(XmlName('sign'), [], [XmlText(state.clefSign)]),
      XmlElement(XmlName('line'), [], [XmlText('${state.clefLine}')]),
    ]));
  }
  if (attributes.findElements('key').isEmpty) {
    attributes.children.add(_hiddenElement('key', [
      XmlElement(XmlName('fifths'), [], [XmlText('${state.keyFifths}')]),
    ]));
  }
  if (attributes.findElements('time').isEmpty) {
    attributes.children.add(_hiddenElement('time', [
      XmlElement(XmlName('beats'), [], [XmlText('${state.beats}')]),
      XmlElement(XmlName('beat-type'), [], [XmlText('${state.beatType}')]),
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
    XmlElement(XmlName(name), [XmlAttribute(XmlName('print-object'), 'no')],
        children);

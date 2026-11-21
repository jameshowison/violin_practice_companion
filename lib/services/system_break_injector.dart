import 'package:xml/xml.dart';

import '../models/engraved_measure_map.dart';
import '../models/section.dart';
import 'package:musicxml_tools/musicxml_tools.dart' show changesMeter;
import 'package:score_view/score_view.dart';

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
/// break fires even on a pickup, since a section-starting pickup has no
/// earlier line to join — except when everything on the line so far is
/// itself pickup: the piece's opening anacrusis before section A's downbeat
/// stays on A's first line instead of standing alone.
///
/// [measuresPerLine] null means no budget at all: only the section starts
/// break, and the lines within a section are left to the caller (the
/// section-aware layout plans those against measured widths).
///
/// Every break also hides the clef/time Verovio would otherwise auto-repeat
/// at the new system (`<clef print-object="no">` etc., carrying the current
/// inherited values; the key signature is left to repeat, see
/// [hideFirstSystemPreamble]), UNLESS this measure already states its own
/// (a genuine change, which should stay visible). This is not cosmetic:
/// Verovio only skips RESERVING the horizontal space for a repeated
/// clef/key/time when it's marked non-printing before layout runs — engraving
/// normally and stripping the glyph out of the rendered SVG afterward (see
/// `VerovioEngraver.clefFirstSystemOnly`) leaves the space reserved and
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
  int? measuresPerLine,
  required List<Section> sections,
}) {
  final doc = XmlDocument.parse(musicXml);

  for (final part in doc.findAllElements('part')) {
    final measures = part.findElements('measure').toList();
    // A section that starts mid-bar is a break before that bar — unless
    // [splitBarsAtSections] has cut the bar there, in which case the cut's
    // continuation slice is where the section (and its line) begins.
    final continued = {
      for (final m in measures)
        if (_continuationOf(m) case final n?) n,
    };
    final sectionStarts = {
      for (final s in sections)
        if (s.startNote == 0 || !continued.contains(s.startMeasure))
          s.startMeasure,
    };
    final state = AttrState();
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
      final isSectionStart =
          (number != null && sectionStarts.contains(number)) ||
              _continuationOf(measure) != null;
      final atBudget = measuresPerLine != null &&
          (count >= measuresPerLine || pendingBreak);

      // A section start whose line so far holds only pickups (the piece's
      // opening anacrusis before section A's downbeat) keeps them: breaking
      // there would leave the pickup alone on a line of its own.
      final sectionBreak = isSectionStart && count > 0;
      if (sectionBreak || (atBudget && !isPickup)) {
        insertPrintBreak(measure);
        hidePreamble(measure, state);
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

/// Cuts each bar in [splits] into consecutive `<measure>`s at the given note
/// (see [sectionBarSplits]), so a section's lead-in can open its line while
/// the rest of its bar ends the line above.
///
/// The first slice keeps the bar's number and ends with an invisible barline
/// (`<bar-style>none</bar-style>`) — it is not a real bar end. Each later
/// slice is numbered `<n>b`, `<n>c`… and marked `implicit="yes"`; its
/// shortness also makes it a pickup to [insertSystemBreaks], which breaks
/// before it as the section's start.
///
/// Notes are counted the way the parser counts them (visible, non-grace;
/// chord members and rests included), so a cut index is the same number as
/// `Section.startNote`. Anything between the note before the cut and the cut
/// note — a chord symbol, a direction, grace notes — travels with the cut
/// note. A left barline stays on the first slice; a right one (or a repeat
/// end) on the last.
///
/// Engraving-only fix-ups at each cut: a beam open across it is ended on one
/// side and restarted on the other, and a lyric extender on the slice's last
/// note is dropped (Verovio would otherwise draw it on into the next line).
/// Ties are left alone: Verovio draws a tie across a measure boundary.
String splitBarsAtSections(String musicXml, List<BarSplit> splits) {
  if (splits.isEmpty) return musicXml;
  final cutsByMeasure = <int, List<int>>{};
  for (final s in splits) {
    (cutsByMeasure[s.measure] ??= []).add(s.note);
  }
  final doc = XmlDocument.parse(musicXml);

  for (final part in doc.findAllElements('part')) {
    final done = <int>{};
    for (final measure in part.findElements('measure').toList()) {
      final number = int.tryParse(measure.getAttribute('number') ?? '');
      final cuts = number == null || done.contains(number)
          ? null
          : cutsByMeasure[number];
      if (cuts == null) continue;
      done.add(number!);
      final sorted = cuts.toSet().toList()..sort();

      // Partition the children into slices.
      final slices = <List<XmlNode>>[[]];
      final pending = <XmlNode>[];
      var noteIndex = 0;
      var cutAt = 0;
      for (final child in measure.children.toList()) {
        final isCounted = child is XmlElement &&
            child.name.local == 'note' &&
            child.findElements('grace').isEmpty &&
            child.getAttribute('print-object') != 'no';
        final isRightBarline = child is XmlElement &&
            child.name.local == 'barline' &&
            child.getAttribute('location') != 'left';
        if (isRightBarline) continue; // re-attached to the last slice below
        if (!isCounted) {
          pending.add(child);
          continue;
        }
        if (cutAt < sorted.length && noteIndex == sorted[cutAt]) {
          slices.add([]);
          cutAt++;
        }
        slices.last
          ..addAll(pending)
          ..add(child);
        pending.clear();
        noteIndex++;
      }
      slices.last.addAll(pending);
      final rightBarlines = measure.findElements('barline')
          .where((b) => b.getAttribute('location') != 'left')
          .toList();
      if (slices.length < 2) continue;

      // Beams and extenders at each seam.
      for (var k = 0; k + 1 < slices.length; k++) {
        final before = _countedNotes(slices[k]).lastOrNull;
        final after = _countedNotes(slices[k + 1]).firstOrNull;
        if (before != null) {
          _closeBeams(before);
          for (final ext in before.findAllElements('extend').toList()) {
            ext.remove();
          }
        }
        if (after != null) _openBeams(after);
      }

      // Rebuild: this measure becomes slice 0; later slices are new measures.
      for (final c in measure.children.toList()) {
        c.remove();
      }
      measure.children.addAll(slices.first.map(_detach));
      measure.children.add(XmlElement(XmlName.parts('barline'), [
        XmlAttribute(XmlName.parts('location'), 'right'),
      ], [
        XmlElement(XmlName.parts('bar-style'), [], [XmlText('none')]),
      ]));
      var anchor = measure;
      for (var k = 1; k < slices.length; k++) {
        final slice = XmlElement(XmlName.parts('measure'), [
          XmlAttribute(XmlName.parts('number'),
              '$number${String.fromCharCode(0x61 + k)}'),
          XmlAttribute(XmlName.parts('implicit'), 'yes'),
        ], [
          ...slices[k].map(_detach),
          if (k == slices.length - 1) ...rightBarlines.map(_detach),
        ]);
        final parent = anchor.parent!;
        parent.children.insert(parent.children.indexOf(anchor) + 1, slice);
        anchor = slice;
      }
    }
  }
  return doc.toXmlString();
}

/// Engraves each [MovedRepeat] in xml that [splitBarsAtSections] has already
/// cut: the backward repeat moves from the close bar's tail slice onto its
/// head, in place of the head's invisible barline, and the forward repeat
/// moves from the `|:` bar to the left edge of the lead-in bar before it.
/// Devil's Dream's `e2 |: … A2 | e2 :|` then reads `|: e2 | … A2 :| e2`.
String moveRepeatsOntoLeadIns(String musicXml, List<MovedRepeat> moved) {
  if (moved.isEmpty) return musicXml;
  final doc = XmlDocument.parse(musicXml);
  bool isRepeat(XmlElement b, String direction) => b
      .findElements('repeat')
      .any((r) => r.getAttribute('direction') == direction);

  for (final part in doc.findAllElements('part')) {
    final measures = part.findElements('measure').toList();
    XmlElement? byNumber(String n) =>
        measures.where((m) => m.getAttribute('number') == n).firstOrNull;
    for (final mr in moved) {
      final head = byNumber('${mr.closeMeasure}');
      final tail = byNumber('${mr.closeMeasure}b');
      final open = byNumber('${mr.openMeasure}');
      final leadIn = byNumber('${mr.leadInMeasure}');
      if (head == null || tail == null || open == null || leadIn == null) {
        continue;
      }
      final backward = tail
          .findElements('barline')
          .where((b) => isRepeat(b, 'backward'))
          .firstOrNull;
      final forward = open
          .findElements('barline')
          .where((b) =>
              b.getAttribute('location') == 'left' && isRepeat(b, 'forward'))
          .firstOrNull;
      if (backward == null || forward == null) continue;
      for (final b in head
          .findElements('barline')
          .where((b) => b.getAttribute('location') != 'left')
          .toList()) {
        b.remove();
      }
      head.children.add(_detach(backward));
      leadIn.children.insert(0, _detach(forward));
    }
  }
  return doc.toXmlString();
}

/// The model measure number a [splitBarsAtSections] continuation slice
/// (`<n>b`, `<n>c`…) belongs to, or null for any ordinary measure.
int? _continuationOf(XmlElement measure) {
  final m = RegExp(r'^(\d+)[b-z]$').firstMatch(measure.getAttribute('number') ?? '');
  return m == null ? null : int.parse(m.group(1)!);
}

XmlNode _detach(XmlNode n) => n.hasParent ? (n..remove()) : n;

Iterable<XmlElement> _countedNotes(List<XmlNode> slice) => slice
    .whereType<XmlElement>()
    .where((e) => e.name.local == 'note' && e.findElements('grace').isEmpty);

/// The slice's last note: a beam still open here ends here.
void _closeBeams(XmlElement note) {
  for (final b in note.findElements('beam').toList()) {
    switch (b.innerText.trim()) {
      case 'begin':
        b.remove(); // a one-note "group"
      case 'continue':
        b.innerText = 'end';
    }
  }
}

/// The next slice's first note: a beam continuing into it starts again here.
void _openBeams(XmlElement note) {
  for (final b in note.findElements('beam').toList()) {
    switch (b.innerText.trim()) {
      case 'end':
        b.remove();
      case 'continue':
        b.innerText = 'begin';
    }
  }
}

/// Freezes system breaks Verovio's own `breaks: 'auto'` layout already chose
/// — [breakMeasureNumbers], each the first measure of a system after the
/// first — into explicit `<print new-system="yes"/>` markers, with the same
/// hidden-preamble treatment [insertSystemBreaks] applies at its own break
/// points. Auto mode's counterpart: the break POSITIONS come from what
/// Verovio already decided (read off the engraved `measureLine`), not from a
/// measures-per-line target — this only recovers the dead margin
/// `VerovioEngraver.clefFirstSystemOnly` otherwise leaves on every
/// continuation line; it doesn't change which measures share a line.
String freezeSystemBreaks(String musicXml, Set<int> breakMeasureNumbers) {
  final doc = XmlDocument.parse(musicXml);

  for (final part in doc.findAllElements('part')) {
    final measures = part.findElements('measure').toList();
    final state = AttrState();

    for (var i = 0; i < measures.length; i++) {
      final measure = measures[i];
      state.update(measure);
      if (i == 0) continue;

      final number = int.tryParse(measure.getAttribute('number') ?? '');
      if (number == null || !breakMeasureNumbers.contains(number)) continue;

      insertPrintBreak(measure);
      hidePreamble(measure, state);
    }
  }

  return doc.toXmlString();
}

/// Hides the piece's own opening clef/time — the same source-level
/// `print-object="no"` trick [hidePreamble] applies to every later system's
/// auto-repeated copy — so Verovio stops RESERVING the horizontal space for it
/// on the very FIRST system too. Confirmed headlessly the same way as that
/// trick: on Old Joe Clark the first note's x moved from 3546 to 1944 once its
/// opening clef/key/time were hidden this way (measured back when the key was
/// hidden too; it no longer is, so the saving is now somewhat smaller).
///
/// The key signature is deliberately left alone (still printed) — unlike
/// clef/time it's cheap to keep restating per line, and doing so is standard
/// notation practice that helps a player who joins mid-line orient themselves.
///
/// Pairs with `buildPreambleXml` (`preamble_xml_generator.dart`), which reads
/// the clef/key/time out of the untouched piece XML for a small standalone
/// preview shown next to the piece title instead — so it must run against a
/// copy of the XML from before this stripping, not after.
///
/// A piece that changes meter keeps its opening time signature on bar 1: one
/// meter in the title bar would misdescribe it, and the changes later in the
/// score read against the one they change from.
String hideFirstSystemPreamble(String musicXml) {
  final doc = XmlDocument.parse(musicXml);
  final hidden = [
    'clef',
    if (!changesMeter(doc)) 'time',
  ];
  for (final part in doc.findAllElements('part')) {
    // Every block, not the first: a scanned piece can split measure 1's
    // attributes, divisions in one and clef/key/time in the next.
    final blocks =
        part.findElements('measure').firstOrNull?.findElements('attributes') ??
            const <XmlElement>[];
    for (final attributes in blocks) {
      for (final name in hidden) {
        attributes.findElements(name).firstOrNull?.setAttribute('print-object', 'no');
      }
    }
  }
  return doc.toXmlString();
}

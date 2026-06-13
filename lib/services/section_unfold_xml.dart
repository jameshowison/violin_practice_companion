import 'package:xml/xml.dart';
import '../models/parsed_piece.dart';
import '../models/piece_layout.dart';
import '../models/section.dart';

/// Rewrites a single-part MusicXML score for section-organized ("ABAA") staff
/// rendering:
///
///  * Repeats are **unfolded** into performance order (a `|: A :|` span is
///    emitted as two consecutive `A` runs — "show up twice in the staff"), and
///    the repeat barlines are removed.
///  * A `<print new-system="yes">` is injected at the first measure of every
///    section run, so each section (and each repeated copy of one) starts a new
///    system. OSMD honors these because the bridge sets `newSystemFromXML`.
///  * Emitted measures are renumbered sequentially so OSMD never sees duplicate
///    measure numbers. The bridge addresses measures by positional index, so
///    the Dart side maps index → original number via its own list (the
///    performance-order numbers) — these attributes are display-only and hidden.
///
/// Run boundaries come from [PieceLayout.sectionRunStarts] so the staff breaks
/// exactly where the jianpu/fingering views do. Call this AFTER layout hints
/// are stripped and any fingerings are injected (unfolding clones whatever is
/// present, so injected fingerings are duplicated into each copy).
class SectionUnfoldXml {
  static String apply(
      String musicXml, List<Measure> measures, List<Section> sections) {
    final order = ParsedPiece.performanceOrder(measures);
    // Nothing to unfold (no repeats) and nothing to break on — leave as-is.
    if (order.length == measures.length && sections.isEmpty) return musicXml;

    final doc = XmlDocument.parse(musicXml);
    final measureEls = doc.findAllElements('measure').toList();
    if (measureEls.isEmpty) return musicXml;
    // Guard against a parsed-model / XML mismatch (e.g. multi-part scores).
    if (measureEls.length != measures.length) return musicXml;

    final runStarts = PieceLayout.sectionRunStarts(measures, sections);
    final part = measureEls.first.parent;
    if (part == null) return musicXml;

    final baseNumber = measures.first.number; // 0 keeps a pickup as a pickup
    final clones = <XmlElement>[];
    for (var oi = 0; oi < order.length; oi++) {
      final clone = measureEls[order[oi]].copy();
      clone.setAttribute('number', '${baseNumber + oi}');

      // Drop repeat barlines (the `|:` / `:|`) — repeats are now unfolded.
      for (final barline in clone.findElements('barline').toList()) {
        if (barline.findElements('repeat').isNotEmpty) {
          clone.children.remove(barline);
        }
      }
      // Drop any pre-existing layout print so only our system breaks remain.
      for (final print in clone.findElements('print').toList()) {
        clone.children.remove(print);
      }
      if (runStarts.contains(oi)) {
        clone.children.insert(
          0,
          XmlElement(XmlName('print'),
              [XmlAttribute(XmlName('new-system'), 'yes')]),
        );
      }
      clones.add(clone);
    }

    part.children.removeWhere((n) => n is XmlElement && n.name.local == 'measure');
    part.children.addAll(clones);

    return doc.toXmlString();
  }
}

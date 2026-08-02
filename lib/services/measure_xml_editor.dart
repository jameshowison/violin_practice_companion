import 'package:xml/xml.dart';

import '../models/duration_step.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';

/// Serializes edited notes back into a piece's MusicXML, one measure at a time.
///
/// Sibling to `fingering_xml_injector.dart` (same parse/mutate/`toXmlString`
/// approach), but it rewrites a measure's note list rather than annotating
/// existing notes, so it's a separate class. Single-voice only — `<backup>`/
/// `<forward>` are out of scope (see `docs/plan.md` §6). Chords aren't editable
/// as such, but a chord member's `<chord/>` marker round-trips so saving an
/// edit doesn't silently break the stack into sequential notes.
class MeasureXmlEditor {
  /// Builds a detached `<note>` element for [note]. `<duration>` is derived
  /// from the note value, dot, and the score's [divisions] (divisions per
  /// quarter note); a quarter note is 8 thirty-second units, so
  /// `duration = units * divisions / 8`.
  static XmlElement buildNoteElement(NoteEvent note, int divisions) =>
      XmlDocument.parse(_noteXml(note, divisions)).rootElement.copy();

  /// Replaces the visible notes of `<measure number="$measureNumber">` with
  /// [notes], leaving `<attributes>`/`<print>`/`<barline>` and any hidden
  /// pickup rests (`print-object="no"`) in place. Returns the re-serialized
  /// MusicXML string.
  static String replaceMeasureNotes(
      String musicXml, int measureNumber, List<NoteEvent> notes, int divisions) {
    final doc = XmlDocument.parse(musicXml);
    final measureEl = doc.findAllElements('measure').firstWhere(
          (m) => m.getAttribute('number') == '$measureNumber',
          orElse: () =>
              throw ArgumentError('Measure $measureNumber not found in MusicXML'),
        );

    final children = measureEl.children;
    bool isVisibleNote(XmlNode n) =>
        n is XmlElement &&
        n.name.local == 'note' &&
        n.getAttribute('print-object') != 'no';

    final visible = children.where(isVisibleNote).toList();
    final int insertIndex;
    if (visible.isNotEmpty) {
      insertIndex = children.indexOf(visible.first);
      children.removeWhere(isVisibleNote);
    } else {
      // No visible notes to replace: insert after the last existing <note>
      // (e.g. hidden pickup rests), else at the end of the measure.
      final lastNoteIdx = children
          .lastIndexWhere((n) => n is XmlElement && n.name.local == 'note');
      insertIndex = lastNoteIdx == -1 ? children.length : lastNoteIdx + 1;
    }

    children.insertAll(
        insertIndex, [for (final n in notes) buildNoteElement(n, divisions)]);
    return doc.toXmlString();
  }

  /// Sets the repeat barlines on `<measure number="$measureNumber">` to match
  /// [start] (forward repeat, left edge `|:`) and [end] (backward repeat, right
  /// edge `:|`, drawn as the doubled `light-heavy` barline). Existing forward/
  /// backward repeat barlines are removed first; non-repeat barlines (e.g. a
  /// plain final double bar) are left untouched. Idempotent. Returns the
  /// re-serialized MusicXML string.
  static String setMeasureRepeats(String musicXml, int measureNumber,
      {required bool start, required bool end}) {
    final doc = XmlDocument.parse(musicXml);
    final measureEl = doc.findAllElements('measure').firstWhere(
          (m) => m.getAttribute('number') == '$measureNumber',
          orElse: () =>
              throw ArgumentError('Measure $measureNumber not found in MusicXML'),
        );

    // Drop the forward/backward repeat barlines we manage; leave any non-repeat
    // barlines in place.
    measureEl.children.removeWhere((n) => _isRepeatBarline(n, 'forward'));
    measureEl.children.removeWhere((n) => _isRepeatBarline(n, 'backward'));

    if (start) _addRepeat(measureEl, forward: true);
    if (end) _addRepeat(measureEl, forward: false);
    return doc.toXmlString();
  }

  /// Rewrites the score's time signature to [beats]/[beatType].
  ///
  /// **Relabels only — note values are untouched.** The case this exists for is
  /// a score whose bars are right and whose `<time>` is wrong: The Wellerman
  /// imported with four quarters in every bar under a `2/4` signature, so every
  /// bar read as double-length and the measure editor flagged the lot. Changing
  /// the label to `2/2` makes the file self-consistent without moving a note.
  /// Re-notating a tune into a different meter (halving or doubling every
  /// duration) is a different operation and deliberately not this one.
  ///
  /// Only the FIRST `<time>` in each part is rewritten. The app's model carries
  /// one meter per piece ([ParsedPiece.beatsPerMeasure] comes from the first
  /// `<time>` in the document), so a mid-piece meter change is already outside
  /// what it can represent — overwriting those too would silently destroy a
  /// distinction the rest of the app can't yet make. A part with no `<time>` at
  /// all gets one, inserted into its first `<attributes>` in the order MusicXML
  /// requires (after `<key>`, before `<clef>`).
  static String setTimeSignature(String musicXml,
      {required int beats, required int beatType}) {
    if (beats < 1 || beatType < 1) {
      throw ArgumentError('Time signature $beats/$beatType is not a meter');
    }
    final doc = XmlDocument.parse(musicXml);
    var changed = false;

    for (final part in doc.findAllElements('part')) {
      final existing = part.findAllElements('time').firstOrNull;
      if (existing != null) {
        _setChildText(existing, 'beats', '$beats');
        _setChildText(existing, 'beat-type', '$beatType');
        changed = true;
        continue;
      }
      final attributes = part.findAllElements('attributes').firstOrNull;
      if (attributes == null) continue;
      final time = XmlDocument.parse(
              '<time><beats>$beats</beats><beat-type>$beatType</beat-type></time>')
          .rootElement
          .copy();
      final clefIdx = attributes.children
          .indexWhere((n) => n is XmlElement && n.name.local == 'clef');
      attributes.children
          .insert(clefIdx == -1 ? attributes.children.length : clefIdx, time);
      changed = true;
    }

    if (!changed) {
      throw ArgumentError('No <attributes> block to hold a time signature');
    }
    return doc.toXmlString();
  }

  /// Sets [element]'s `<$name>` child to [text], creating it if absent.
  static void _setChildText(XmlElement element, String name, String text) {
    final child = element.findElements(name).firstOrNull;
    if (child == null) {
      element.children.add(XmlElement(XmlName(name), [], [XmlText(text)]));
    } else {
      child.innerText = text;
    }
  }

  /// Deletes `<measure number="$measureNumber">` from every part and renumbers
  /// the measures that follow so numbering stays consecutive (a pickup measure
  /// numbered 0 keeps its 0).
  ///
  /// The deleted bar's *context* is handed to its neighbours, so removing a bar
  /// doesn't silently change how the rest of the piece engraves or sounds:
  ///  * `<attributes>` — when the deleted bar was the part's first, its
  ///    divisions/key/time/clef are merged into the next measure (tag by tag,
  ///    never overwriting one the next measure already states), otherwise the
  ///    score would lose its key and time signature.
  ///  * repeat barlines — a `|:` moves to the next measure's left edge and a
  ///    `:|` to the previous measure's right edge, so a repeated strain keeps
  ///    its brackets (and the piece keeps its performance order).
  ///  * `<harmony>` — the deleted bar's last chord symbol is copied to the head
  ///    of the next measure when that measure states no chord of its own, since
  ///    the chord it introduced is still the one sounding.
  ///
  /// Throws [ArgumentError] when no part contains the measure, or when it is the
  /// only measure a part has (a part must keep at least one).
  static String deleteMeasure(String musicXml, int measureNumber) {
    final doc = XmlDocument.parse(musicXml);
    var deleted = false;

    for (final part in doc.findAllElements('part')) {
      final measures = part.findElements('measure').toList();
      final idx =
          measures.indexWhere((m) => m.getAttribute('number') == '$measureNumber');
      if (idx < 0) continue;
      if (measures.length <= 1) {
        throw ArgumentError('Cannot delete measure $measureNumber: '
            'a part must keep at least one measure');
      }
      final target = measures[idx];
      final prev = idx > 0 ? measures[idx - 1] : null;
      final next = idx + 1 < measures.length ? measures[idx + 1] : null;

      if (idx == 0 && next != null) _carryAttributes(target, next);
      if (_hasRepeat(target, 'forward') && next != null) {
        _addRepeat(next, forward: true);
      }
      if (_hasRepeat(target, 'backward') && prev != null) {
        _addRepeat(prev, forward: false);
      }
      if (next != null) _carryHarmony(target, next);

      part.children.remove(target);
      _renumberMeasures(part);
      deleted = true;
    }

    if (!deleted) {
      throw ArgumentError('Measure $measureNumber not found in MusicXML');
    }
    return doc.toXmlString();
  }

  // ── deleteMeasure helpers ────────────────────────────────────────────────

  static bool _isRepeatBarline(XmlNode n, String direction) =>
      n is XmlElement &&
      n.name.local == 'barline' &&
      n.findElements('repeat')
          .any((r) => r.getAttribute('direction') == direction);

  static bool _hasRepeat(XmlElement measure, String direction) =>
      measure.children.any((n) => _isRepeatBarline(n, direction));

  /// Adds a forward (left edge) or backward (right edge) repeat barline to
  /// [measure]. No-op when that repeat is already there, so moving a repeat onto
  /// a bar that already carries one can't double it up.
  static void _addRepeat(XmlElement measure, {required bool forward}) {
    if (_hasRepeat(measure, forward ? 'forward' : 'backward')) return;
    if (forward) {
      final barline = XmlDocument.parse(
              '<barline location="left"><bar-style>heavy-light</bar-style>'
              '<repeat direction="forward"/></barline>')
          .rootElement
          .copy();
      // A left barline belongs at the start of the measure, after a leading
      // <print> if one is present.
      final printIdx = measure.children
          .indexWhere((n) => n is XmlElement && n.name.local == 'print');
      measure.children.insert(printIdx == -1 ? 0 : printIdx + 1, barline);
    } else {
      measure.children.add(
          XmlDocument.parse('<barline location="right">'
                  '<bar-style>light-heavy</bar-style>'
                  '<repeat direction="backward"/></barline>')
              .rootElement
              .copy());
    }
  }

  /// MusicXML child-order within `<attributes>`, so a merged block stays
  /// schema-ordered (importers read divisions before it means anything).
  static const _attrOrder = [
    'footnote', 'level', 'divisions', 'key', 'time', 'staves', 'part-symbol',
    'instruments', 'clef', 'staff-details', 'measure-style',
  ];

  /// Merges [from]'s `<attributes>` children into [to], skipping any tag [to]
  /// already states (its own value is the more specific one) and re-sorting the
  /// result into schema order.
  static void _carryAttributes(XmlElement from, XmlElement to) {
    final donors = from.findElements('attributes').toList();
    if (donors.isEmpty) return;
    final present = <String>{
      for (final a in to.findElements('attributes'))
        for (final c in a.childElements) c.name.local,
    };
    final carried = <XmlElement>[
      for (final a in donors)
        for (final c in a.childElements)
          if (!present.contains(c.name.local)) c.copy(),
    ];
    if (carried.isEmpty) return;

    var block = to.findElements('attributes').firstOrNull;
    if (block == null) {
      block = XmlElement(XmlName('attributes'));
      // <attributes> precedes the measure's notes; a <print> stays first.
      final printIdx = to.children
          .indexWhere((n) => n is XmlElement && n.name.local == 'print');
      to.children.insert(printIdx == -1 ? 0 : printIdx + 1, block);
    }
    final merged = [...block.childElements.map((e) => e.copy()), ...carried]
      ..sort((a, b) => _attrRank(a).compareTo(_attrRank(b)));
    block.children
      ..clear()
      ..addAll(merged);
  }

  static int _attrRank(XmlElement e) {
    final i = _attrOrder.indexOf(e.name.local);
    return i < 0 ? _attrOrder.length : i;
  }

  /// Copies [from]'s last `<harmony>` to the head of [to] when [to] states no
  /// chord before its first note — the chord [from] introduced is still
  /// sounding, so it should keep a symbol rather than reverting to the one
  /// before it. A `<harmony>` belongs immediately before the note it applies to.
  static void _carryHarmony(XmlElement from, XmlElement to) {
    final donor = from.findElements('harmony').lastOrNull;
    if (donor == null) return;
    final children = to.children;
    final firstNoteIdx =
        children.indexWhere((n) => n is XmlElement && n.name.local == 'note');
    final headHarmonyIdx =
        children.indexWhere((n) => n is XmlElement && n.name.local == 'harmony');
    final statesOwnChord = headHarmonyIdx != -1 &&
        (firstNoteIdx == -1 || headHarmonyIdx < firstNoteIdx);
    if (statesOwnChord) return;
    children.insert(firstNoteIdx == -1 ? children.length : firstNoteIdx,
        donor.copy());
  }

  /// Renumbers [part]'s measures 1, 2, 3, … in document order. A measure
  /// numbered 0 (a pickup) keeps its 0; a non-numeric number (e.g. an OMR
  /// "1a") is left alone.
  static void _renumberMeasures(XmlElement part) {
    var n = 1;
    for (final m in part.findElements('measure')) {
      final cur = int.tryParse(m.getAttribute('number') ?? '');
      if (cur == null || cur == 0) continue;
      m.setAttribute('number', '${n++}');
    }
  }

  /// A minimal single-measure `<score-partwise>` for the live edit preview.
  /// Same structure proven to render with `StaffView` + the palette OSMD
  /// bridge (`PaletteXmlGenerator`): one part/measure with a synthesized
  /// `<attributes>` (divisions/key/time/treble clef) followed by [notes].
  static String buildSingleMeasurePreviewXml(
      List<NoteEvent> notes, ParsedPiece parsed,
      {bool repeatStart = false, bool repeatEnd = false}) {
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<score-partwise version="3.1">')
      ..writeln('<part-list>'
          '<score-part id="P1"><part-name/></score-part>'
          '</part-list>')
      ..writeln('<part id="P1">')
      ..writeln('<measure number="1">')
      ..writeln('<attributes>'
          '<divisions>${parsed.divisions}</divisions>'
          '<key><fifths>${parsed.keyFifths}</fifths></key>'
          '<time><beats>${parsed.beatsPerMeasure}</beats>'
          '<beat-type>${parsed.beatType}</beat-type></time>'
          '<clef><sign>G</sign><line>2</line></clef>'
          '</attributes>');
    if (repeatStart) {
      buf.writeln('<barline location="left"><bar-style>heavy-light</bar-style>'
          '<repeat direction="forward"/></barline>');
    }
    for (final n in notes) {
      buf.writeln(_noteXml(n, parsed.divisions));
    }
    if (repeatEnd) {
      buf.writeln('<barline location="right"><bar-style>light-heavy</bar-style>'
          '<repeat direction="backward"/></barline>');
    }
    buf
      ..writeln('</measure>')
      ..writeln('</part>')
      ..writeln('</score-partwise>');
    return buf.toString();
  }

  static String _noteXml(NoteEvent n, int divisions) {
    final dur = _durationDivisions(n, divisions);
    final type = _typeName(n.noteValue);
    final dot = n.dotted ? '<dot/>' : '';
    // The visible accidental sign — emitted verbatim so a courtesy natural (or
    // any explicit sign) round-trips. MusicXML order: after <dot>, before
    // <notations>. null means "follow the key signature, no sign drawn".
    final accidental =
        n.displayAccidental != null ? '<accidental>${n.displayAccidental}</accidental>' : '';
    final fingering = n.scoreFinger != null
        ? '<notations><technical>'
            '<fingering>${n.scoreFinger}</fingering>'
            '</technical></notations>'
        : '';
    if (n.isRest) {
      return '<note><rest/><duration>$dur</duration><type>$type</type>$dot</note>';
    }
    // A chord member's marker comes first in MusicXML's <note> child order,
    // before <pitch>. Rests are never chord members.
    final chord = n.isChord ? '<chord/>' : '';
    final p = _parsePitch(n.pitch);
    final alter = p.alter != 0 ? '<alter>${p.alter}</alter>' : '';
    return '<note>'
        '$chord'
        '<pitch><step>${p.step}</step>$alter<octave>${p.octave}</octave></pitch>'
        '<duration>$dur</duration>'
        '<type>$type</type>'
        '$dot'
        '$accidental'
        '$fingering'
        '</note>';
  }

  static int _durationDivisions(NoteEvent n, int divisions) {
    final units = thirtySecondUnits(n.noteValue, n.dotted); // quarter = 8
    final dur = (units * divisions / 8).round();
    return dur < 1 ? 1 : dur;
  }

  static String _typeName(NoteValue v) => switch (v) {
        NoteValue.whole => 'whole',
        NoteValue.half => 'half',
        NoteValue.quarter => 'quarter',
        NoteValue.eighth => 'eighth',
        NoteValue.sixteenth => '16th',
      };

  static ({String step, int alter, int octave}) _parsePitch(String pitch) {
    final m = RegExp(r'^([A-G])([#b]?)(\d)$').firstMatch(pitch);
    if (m == null) return (step: 'C', alter: 0, octave: 4);
    final alter = m.group(2) == '#'
        ? 1
        : m.group(2) == 'b'
            ? -1
            : 0;
    return (step: m.group(1)!, alter: alter, octave: int.parse(m.group(3)!));
  }
}

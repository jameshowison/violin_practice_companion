import 'package:xml/xml.dart';

import '../models/duration_step.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';

/// Serializes edited notes back into a piece's MusicXML, one measure at a time.
///
/// Sibling to `fingering_xml_injector.dart` (same parse/mutate/`toXmlString`
/// approach), but it rewrites a measure's note list rather than annotating
/// existing notes, so it's a separate class. Single-voice only — `<backup>`/
/// `<forward>`/chords are out of scope (see `docs/plan.md` §6).
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

  /// A minimal single-measure `<score-partwise>` for the live edit preview.
  /// Same structure proven to render with `StaffView` + the palette OSMD
  /// bridge (`PaletteXmlGenerator`): one part/measure with a synthesized
  /// `<attributes>` (divisions/key/time/treble clef) followed by [notes].
  static String buildSingleMeasurePreviewXml(
      List<NoteEvent> notes, ParsedPiece parsed) {
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
    for (final n in notes) {
      buf.writeln(_noteXml(n, parsed.divisions));
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
    final p = _parsePitch(n.pitch);
    final alter = p.alter != 0 ? '<alter>${p.alter}</alter>' : '';
    return '<note>'
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

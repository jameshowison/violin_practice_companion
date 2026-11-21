import 'package:musicxml_tools/musicxml_tools.dart';

import 'fingering_mapper.dart';

/// Moves open-string / 4th-finger choices out of a score and into the violin
/// layer (docs/family/layers.md, migration step 2).
///
/// The measure editor used to store such a choice as the note's own
/// `<fingering>` 0 or 4, inside the shared score, where it was a violin's
/// decision written into everyone's music. A scanned score's printed 0 or 4
/// on those notes is the same kind of decision. Both become
/// `InstrumentLayerStore` string choices, keyed `<measure>:<index>`.
///
/// Only a 0 or 4 on a note that has the choice ([FingeringMapper
/// .hasFourthFingerChoice]: D4, A4, E5) moves; other fingerings stay in the
/// score. Each bar that loses one is rewritten by [MeasureXmlEditor
/// .replaceMeasureNotes], the writer Save uses.
class StringChoiceMigration {
  StringChoiceMigration._();

  /// [musicXml] without its string choices, and the choices it had. The same
  /// string and no choices when there was nothing to move.
  static ({String xml, Map<String, int> choices}) extract(String musicXml) {
    if (!musicXml.contains('<fingering')) {
      return (xml: musicXml, choices: const {});
    }
    final parsed = MusicXmlParser().parse(musicXml);
    var xml = musicXml;
    final choices = <String, int>{};
    for (final m in parsed.measures) {
      final notes = [...m.notes];
      var changed = false;
      for (var i = 0; i < notes.length; i++) {
        final n = notes[i];
        final f = n.scoreFinger;
        if (n.isRest || (f != 0 && f != 4)) continue;
        if (!FingeringMapper.hasFourthFingerChoice(n.midiNumber)) continue;
        choices['${m.number}:$i'] = f!;
        notes[i] = n.copyWith(clearScoreFinger: true);
        changed = true;
      }
      if (changed) {
        xml = MeasureXmlEditor.replaceMeasureNotes(
            xml, m.number, notes, parsed.divisions);
      }
    }
    return (xml: choices.isEmpty ? musicXml : xml, choices: choices);
  }

  /// A bar's string choices as the measure editor holds them (a 0 or 4
  /// [NoteEvent.scoreFinger] on a note with the choice), by note index.
  static Map<int, int> ofNotes(List<NoteEvent> notes) => {
        for (var i = 0; i < notes.length; i++)
          if (!notes[i].isRest &&
              (notes[i].scoreFinger == 0 || notes[i].scoreFinger == 4) &&
              FingeringMapper.hasFourthFingerChoice(notes[i].midiNumber))
            i: notes[i].scoreFinger!,
      };

  /// [notes] with those choices taken off, to be written into the score.
  static List<NoteEvent> withoutChoices(List<NoteEvent> notes) {
    final pinned = ofNotes(notes);
    if (pinned.isEmpty) return notes;
    return [
      for (var i = 0; i < notes.length; i++)
        pinned.containsKey(i)
            ? notes[i].copyWith(clearScoreFinger: true)
            : notes[i],
    ];
  }

  /// [notes] with a bar's stored choices put on, for the editor to show and
  /// change. A note that already carries a 0 or 4 keeps it.
  static List<NoteEvent> withChoices(
      List<NoteEvent> notes, Map<int, int> forMeasure) {
    if (forMeasure.isEmpty) return notes;
    return [
      for (var i = 0; i < notes.length; i++)
        switch (forMeasure[i]) {
          final f? when notes[i].scoreFinger == null && !notes[i].isRest =>
            notes[i].copyWith(scoreFinger: f),
          _ => notes[i],
        },
    ];
  }
}

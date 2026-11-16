import '../models/note_event.dart';
import 'chord_editor.dart';

/// The measure editor's triplet toggle: makes the selected note and the two
/// after it a triplet (three in the time of two), or undoes the triplet the
/// selected note is in.
///
/// It exists for what a scan gets wrong both ways. The recogniser reads a
/// fingering "3" over three notes as a triplet, and real triplets are rare
/// enough in a student's music that the scan-time repair ([TupletRepair])
/// can't always tell them apart; this is where a parent puts it right, guided
/// by the bar's beat count.
///
/// Pure list operations, like [ChordEditor]; chord members ride with their
/// primary note.
class TupletEditor {
  static const triplet = (actual: 3, normal: 2);

  /// The tuplet group (start inclusive, end exclusive) holding [i], or null.
  static (int, int)? groupOf(List<NoteEvent> notes, int? i) {
    if (i == null || i < 0 || i >= notes.length) return null;
    for (final g in tupletGroups(notes)) {
      if (i >= g.$1 && i < g.$2) return g;
    }
    return null;
  }

  /// The three primary notes a triplet starting at [i] would take, or null
  /// with why not in [blockedReason].
  static List<int>? _members(List<NoteEvent> notes, int i) {
    final first = ChordEditor.primaryIndexOf(notes, i);
    final picked = <int>[];
    for (var k = first; k < notes.length && picked.length < 3; k++) {
      if (notes[k].isChord && k > 0) continue;
      picked.add(k);
    }
    if (picked.length < 3) return null;
    final a = notes[picked.first];
    final same = picked.every((k) =>
        notes[k].noteValue == a.noteValue &&
        notes[k].dotted == a.dotted &&
        notes[k].tuplet == null);
    return same ? picked : null;
  }

  /// Why the selected note can't start a triplet, or null if it can (or is
  /// already in one, which the toggle undoes).
  static String? blockedReason(List<NoteEvent> notes, int? i) {
    if (i == null) return 'Select the first note of the three.';
    if (groupOf(notes, i) != null) return null;
    if (_members(notes, i) == null) {
      return 'A triplet needs this note and the next two, all the same '
          'length and not already in one.';
    }
    return null;
  }

  /// [notes] with the triplet holding [i] undone, or with [i] and the next
  /// two notes made one. Unchanged when [blockedReason] says no.
  static List<NoteEvent> toggle(List<NoteEvent> notes, int i) {
    final out = [...notes];
    final g = groupOf(notes, i);
    if (g != null) {
      for (var k = g.$1; k < g.$2; k++) {
        out[k] = out[k].copyWith(clearTuplet: true);
      }
      return out;
    }
    final picked = _members(notes, i);
    if (picked == null) return out;
    var end = picked.last + 1;
    while (end < notes.length && notes[end].isChord) {
      end++;
    }
    for (var k = picked.first; k < end; k++) {
      out[k] = out[k].copyWith(tuplet: triplet);
    }
    return out;
  }
}

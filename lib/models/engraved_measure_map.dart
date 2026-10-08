import 'note_event.dart';
import 'parsed_piece.dart';
import 'section.dart';

/// Where a model measure is cut in two for engraving, before its [note]-th
/// note (positional, rests and chord members counted — the same index as
/// `Section.startNote` and `HighlightEvent.noteIndex`).
typedef BarSplit = ({int measure, int note});

/// The bars a section-aware staff layout splits: every section that starts
/// MID-bar (on a lead-in, `startNote > 0`) cuts its bar there, so the lead-in
/// can open the section's first line while the rest of the bar ends the line
/// above it. A section on a downbeat needs no cut.
///
/// Skipped: the piece's first measure (nothing above it to end a line), a cut
/// at or past the bar's last note, and duplicates. A cut on a chord member
/// would separate it from its stem, so it moves back to the chord's primary
/// note (and is dropped if that lands on 0). Sorted in document order.
List<BarSplit> sectionBarSplits(List<Section> sections, List<Measure> measures) {
  if (measures.isEmpty) return const [];
  final indexOf = {for (var i = 0; i < measures.length; i++) measures[i].number: i};
  final out = <BarSplit>{};
  for (final s in sections) {
    final i = indexOf[s.startMeasure];
    if (i == null || i == 0) continue;
    final notes = measures[i].notes;
    var note = s.startNote;
    if (note <= 0 || note >= notes.length) continue;
    while (note > 0 && notes[note].isChord) {
      note--;
    }
    if (note <= 0) continue;
    out.add((measure: s.startMeasure, note: note));
  }
  return out.toList()
    ..sort((a, b) {
      final c = indexOf[a.measure]!.compareTo(indexOf[b.measure]!);
      return c != 0 ? c : a.note.compareTo(b.note);
    });
}

/// A `:|` bar whose tail a section split sends to the next line, where a
/// player repeating would never see it. Devil's Dream's `e2 |: … A2 e2 :|`:
/// the tail `e2` opens B's line, yet it is also the lead-in back into A. When
/// that tail is the same music as the lead-in before the `|:`, a section
/// layout engraves the equivalent `|: e2 | … A2 :| e2 |: …` instead — the
/// backward repeat on [closeMeasure]'s head, the forward one moved from
/// [openMeasure] onto [leadInMeasure] — so each pass reads its own lead-in.
///
/// [tailNote] is where [closeMeasure] is cut, as in [BarSplit]. The lead-in
/// is all of [leadInMeasure], the bar before [openMeasure]; a lead-in that
/// is itself a split tail (a first ending's, say) is not handled.
typedef MovedRepeat = ({
  int closeMeasure,
  int tailNote,
  int openMeasure,
  int leadInMeasure,
});

/// The repeats a section layout moves onto their lead-ins (see [MovedRepeat]).
List<MovedRepeat> movedRepeats(List<Section> sections, List<Measure> measures) {
  final out = <MovedRepeat>[];
  final indexOf = {for (var i = 0; i < measures.length; i++) measures[i].number: i};
  for (final split in sectionBarSplits(sections, measures)) {
    final c = indexOf[split.measure]!;
    final close = measures[c];
    if (!close.repeatEnd) continue;
    final o = repeatTargetIndex(measures, c);
    if (o <= 0) continue;
    final leadIn = measures[o - 1];
    if (!sections.any((s) => s.startMeasure == leadIn.number && s.startNote == 0)) {
      continue;
    }
    if (!sameMusic(close.notes.sublist(split.note), leadIn.notes)) continue;
    out.add((
      closeMeasure: close.number,
      tailNote: split.note,
      openMeasure: measures[o].number,
      leadInMeasure: leadIn.number,
    ));
  }
  return out;
}

/// The index a `:|` at [closeIndex] jumps back to, as
/// [ParsedPiece.performanceOrder] plays it: the last `|:` at or before it,
/// else the piece's start.
int repeatTargetIndex(List<Measure> measures, int closeIndex) {
  for (var i = closeIndex; i >= 0; i--) {
    if (measures[i].repeatStart) return i;
  }
  return 0;
}

/// Whether two runs of notes play the same: pitches, rhythms, rests, chords
/// and ties alike.
bool sameMusic(List<NoteEvent> a, List<NoteEvent> b) {
  if (a.length != b.length || a.isEmpty) return false;
  for (var k = 0; k < a.length; k++) {
    final x = a[k], y = b[k];
    if (x.isRest != y.isRest ||
        (!x.isRest && x.midiNumber != y.midiNumber) ||
        x.noteValue != y.noteValue ||
        x.dotted != y.dotted ||
        x.isChord != y.isChord ||
        x.tieStart != y.tieStart ||
        x.tieStop != y.tieStop) {
      return false;
    }
  }
  return true;
}

/// The engraved staff's measures, in engraved order, each tied back to the
/// model measure it shows — the translation between what Verovio numbers
/// (engraved measure INDEX, note index within that engraved measure) and what
/// the rest of the app speaks (measure NUMBER, note index within the model
/// measure).
///
/// Usually one-to-one. A split bar ([sectionBarSplits]) engraves as two
/// measures that are one model measure: the second slice carries the same
/// [numberAt] with a [noteOffsetAt] equal to the cut, so model note `j` of that
/// bar is engraved note `j - offset` of the slice holding it.
///
/// Repeated numbers (an unfolded performance order) are also allowed; lookups
/// by number then resolve to the first rendered copy, as before.
class EngravedMeasureMap {
  final List<({int number, int noteOffset})> slices;

  /// The layout's [MovedRepeat]s, and the performance order (indices into
  /// the model measures) that tells which pass of a repeat a note plays on —
  /// see [playedAt].
  final List<MovedRepeat> moved;
  final List<int> order;

  const EngravedMeasureMap(this.slices,
      {this.moved = const [], this.order = const []});

  static const empty = EngravedMeasureMap([]);

  /// One engraved measure per number, none split.
  factory EngravedMeasureMap.identity(Iterable<int> numbers) =>
      EngravedMeasureMap([for (final n in numbers) (number: n, noteOffset: 0)]);

  /// [measures] in document order, with each bar in [splits] engraved as
  /// consecutive slices.
  factory EngravedMeasureMap.withSplits(
      List<Measure> measures, List<BarSplit> splits,
      {List<MovedRepeat> moved = const [], List<int> order = const []}) {
    final cuts = <int, List<int>>{};
    for (final s in splits) {
      (cuts[s.measure] ??= []).add(s.note);
    }
    return EngravedMeasureMap([
      for (final m in measures) ...[
        (number: m.number, noteOffset: 0),
        for (final c in [...?cuts[m.number]]..sort())
          (number: m.number, noteOffset: c),
      ],
    ], moved: moved, order: order);
  }

  int get length => slices.length;
  bool get isEmpty => slices.isEmpty;

  /// Whether any model measure engraves as more than one slice.
  bool get hasSplits => slices.any((s) => s.noteOffset > 0);

  /// The model measure number per engraved index.
  List<int> get numbers => [for (final s in slices) s.number];

  int numberAt(int index) => slices[index].number;
  int noteOffsetAt(int index) => slices[index].noteOffset;

  /// The first engraved slice of measure [number], or -1.
  int firstIndexOf(int number) {
    for (var i = 0; i < slices.length; i++) {
      if (slices[i].number == number) return i;
    }
    return -1;
  }

  /// The last engraved slice of the first copy of measure [number], or -1.
  int lastIndexOf(int number) {
    var i = firstIndexOf(number);
    if (i < 0) return -1;
    while (i + 1 < slices.length &&
        slices[i + 1].number == number &&
        slices[i + 1].noteOffset > 0) {
      i++;
    }
    return i;
  }

  /// Every engraved slice of the first copy of measure [number].
  Iterable<int> indicesOf(int number) sync* {
    final first = firstIndexOf(number);
    if (first < 0) return;
    for (var i = first; i <= lastIndexOf(number); i++) {
      yield i;
    }
  }

  /// Model note [noteIndex] of measure [number] → the engraved slice holding it
  /// and its index there. Null when the measure isn't engraved.
  ({int index, int note})? locate(int number, int noteIndex) {
    final first = firstIndexOf(number);
    if (first < 0) return null;
    var i = first;
    while (i + 1 <= lastIndexOf(number) &&
        slices[i + 1].noteOffset <= noteIndex) {
      i++;
    }
    return (index: i, note: noteIndex - slices[i].noteOffset);
  }

  /// Where the staff draws model note [noteIndex] of measure [number] when it
  /// plays at [performanceIndex] of [order]. A note in a moved repeat's tail,
  /// on the pass that jumps back, is drawn on the lead-in it duplicates;
  /// everything else where it is written.
  ({int number, int note}) playedAt(
      int number, int noteIndex, int performanceIndex) {
    for (final mr in moved) {
      if (mr.closeMeasure != number || noteIndex < mr.tailNote) continue;
      final next = performanceIndex + 1;
      if (performanceIndex < 0 || next >= order.length) continue;
      if (order[next] > order[performanceIndex]) continue; // falls through
      return (number: mr.leadInMeasure, note: noteIndex - mr.tailNote);
    }
    return (number: number, note: noteIndex);
  }

  /// [locate] for a note playing at [performanceIndex] (see [playedAt]).
  ({int index, int note})? locatePlayed(
      int number, int noteIndex, int performanceIndex) {
    final at = playedAt(number, noteIndex, performanceIndex);
    return locate(at.number, at.note);
  }

  /// A model range — inclusive [startMeasure]/[startNote], and [endMeasure]
  /// with an EXCLUSIVE [endNote] (`-1` = the whole of [endMeasure]), the shape
  /// `resolveSectionRanges` produces — in engraved coordinates of the same
  /// shape. Null when either end isn't engraved. With [startPerf], the start
  /// is the note as it plays at that performance index ([playedAt]), so a
  /// pass that begins on a moved repeat's tail is drawn from its lead-in.
  ({int startMeasureIndex, int startNote, int endMeasureIndex, int endNote})?
      range(int startMeasure, int startNote, int endMeasure, int endNote,
          {int startPerf = -1}) {
    final start = locatePlayed(startMeasure, startNote, startPerf);
    if (start == null) return null;
    int endIndex;
    int endNoteOut;
    if (endNote < 0) {
      endIndex = lastIndexOf(endMeasure);
      endNoteOut = -1;
    } else if (endNote == 0) {
      // Ends before the bar's first note: nothing of it is covered. Keep the
      // historical shape (the bar's index with an empty exclusive end).
      endIndex = firstIndexOf(endMeasure);
      endNoteOut = 0;
    } else {
      // Exclusive end: the slice holding the last INCLUDED note.
      final last = locate(endMeasure, endNote - 1);
      if (last == null) return null;
      endIndex = last.index;
      endNoteOut = last.note + 1;
      // Ends exactly at its slice's end: say "the whole slice", so a section
      // ending on a split never claims a note of the next slice.
      final nextIsSameBar = endIndex + 1 < slices.length &&
          slices[endIndex + 1].number == endMeasure &&
          slices[endIndex + 1].noteOffset == endNote;
      if (nextIsSameBar) endNoteOut = -1;
    }
    if (endIndex < 0) return null;
    return (
      startMeasureIndex: start.index,
      startNote: start.note,
      endMeasureIndex: endIndex,
      endNote: endNoteOut,
    );
  }
}

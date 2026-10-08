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

  const EngravedMeasureMap(this.slices);

  static const empty = EngravedMeasureMap([]);

  /// One engraved measure per number, none split.
  factory EngravedMeasureMap.identity(Iterable<int> numbers) =>
      EngravedMeasureMap([for (final n in numbers) (number: n, noteOffset: 0)]);

  /// [measures] in document order, with each bar in [splits] engraved as
  /// consecutive slices.
  factory EngravedMeasureMap.withSplits(
      List<Measure> measures, List<BarSplit> splits) {
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
    ]);
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

  /// A model range — inclusive [startMeasure]/[startNote], and [endMeasure]
  /// with an EXCLUSIVE [endNote] (`-1` = the whole of [endMeasure]), the shape
  /// `resolveSectionRanges` produces — in engraved coordinates of the same
  /// shape. Null when either end isn't engraved.
  ({int startMeasureIndex, int startNote, int endMeasureIndex, int endNote})?
      range(int startMeasure, int startNote, int endMeasure, int endNote) {
    final start = locate(startMeasure, startNote);
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

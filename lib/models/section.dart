import 'parsed_piece.dart';

/// One section START marker, in document order within a piece. A section runs
/// from its marker until the next marker (or the end of the piece) — so the
/// ordered list of markers is the piece's section structure, at note-level
/// granularity.
///
/// [startNote] is the positional index into the start measure's notes (0 = the
/// bar's first note), which lets a section begin mid-measure — e.g. so a pickup
/// note belongs to the section that follows it.
class Section {
  final String label;
  final int startMeasure; // measure NUMBER where it begins (0 = a pickup measure)
  final int startNote; // index into that measure's notes; 0 = bar start

  const Section({
    required this.label,
    required this.startMeasure,
    this.startNote = 0,
  });

  /// Tolerant of the legacy `{label,startMeasure,endMeasure}` shape: the
  /// `endMeasure` key is ignored (section ends are now implicit — derived from
  /// the next marker). `startNote` defaults to 0 when absent.
  factory Section.fromJson(Map<String, dynamic> json) => Section(
        label: json['label'] as String,
        startMeasure: json['startMeasure'] as int,
        startNote: (json['startNote'] as int?) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'startMeasure': startMeasure,
        'startNote': startNote,
      };

  @override
  bool operator ==(Object other) =>
      other is Section &&
      other.label == label &&
      other.startMeasure == startMeasure &&
      other.startNote == startNote;

  @override
  int get hashCode => Object.hash(label, startMeasure, startNote);
}

/// A resolved section span over the document measures: a contiguous run from a
/// start marker up to the next marker. Bounds are inclusive measure NUMBERS;
/// [startNote]/[endNote] give the note-level edges within the boundary measures.
/// [endNote] is EXCLUSIVE within [endMeasure]; `-1` means "the whole
/// [endMeasure]" (the section runs to the end of that measure).
typedef SectionRange = ({
  String label,
  int startMeasure,
  int startNote,
  int endMeasure,
  int endNote,
});

/// Resolves [starts] (section markers, any order) into contiguous ranges over
/// [measures]. Each range ends where the next begins; the last runs to the end
/// of the piece. Markers whose measure is absent from [measures] are dropped.
/// Measures before the first marker (e.g. an unmarked pickup) are covered by no
/// range.
List<SectionRange> resolveSectionRanges(
    List<Section> starts, List<Measure> measures) {
  if (starts.isEmpty || measures.isEmpty) return const [];
  final indexOfNumber = <int, int>{
    for (var i = 0; i < measures.length; i++) measures[i].number: i,
  };
  final sorted = [
    for (final s in starts)
      if (indexOfNumber.containsKey(s.startMeasure)) s
  ]..sort((a, b) {
      final ia = indexOfNumber[a.startMeasure]!;
      final ib = indexOfNumber[b.startMeasure]!;
      return ia != ib ? ia.compareTo(ib) : a.startNote.compareTo(b.startNote);
    });
  if (sorted.isEmpty) return const [];

  final ranges = <SectionRange>[];
  for (var i = 0; i < sorted.length; i++) {
    final s = sorted[i];
    final next = i + 1 < sorted.length ? sorted[i + 1] : null;
    if (next == null) {
      ranges.add((
        label: s.label,
        startMeasure: s.startMeasure,
        startNote: s.startNote,
        endMeasure: measures.last.number,
        endNote: -1, // to end of piece
      ));
    } else if (next.startNote > 0) {
      // The boundary measure is shared: this section ends just before the next
      // marker's note within that same measure.
      ranges.add((
        label: s.label,
        startMeasure: s.startMeasure,
        startNote: s.startNote,
        endMeasure: next.startMeasure,
        endNote: next.startNote,
      ));
    } else {
      // The next section begins at a bar line, so this one ends at the whole
      // measure just before it (in document order).
      final endIdx = (indexOfNumber[next.startMeasure]! - 1)
          .clamp(0, measures.length - 1);
      ranges.add((
        label: s.label,
        startMeasure: s.startMeasure,
        startNote: s.startNote,
        endMeasure: measures[endIdx].number,
        endNote: -1,
      ));
    }
  }
  return ranges;
}

/// Measure NUMBER → section label, at measure granularity (a mid-measure start
/// colors its whole boundary measure as the new section). Measures before the
/// first marker get no entry. Used by the row-based jianpu/fingering grouping
/// and the section bar, which can't split a measure.
Map<int, String> sectionLabelByMeasure(
    List<Section> starts, List<Measure> measures) {
  if (starts.isEmpty) return const {};
  final markerLabel = <int, String>{
    for (final s in starts) s.startMeasure: s.label, // last marker at a measure wins
  };
  final map = <int, String>{};
  String? cur;
  for (final m in measures) {
    if (markerLabel.containsKey(m.number)) cur = markerLabel[m.number];
    if (cur != null) map[m.number] = cur;
  }
  return map;
}

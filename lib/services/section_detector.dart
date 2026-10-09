import 'dart:math' as math;

import '../models/duration_step.dart';
import '../models/engraved_measure_map.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/section.dart';

/// Detects a tune's sectional form (AABB, ABAA, …) from its parsed measures and
/// returns section START markers (`Section` list). Restated strains reuse the
/// same label, so the existing section machinery renders the form correctly:
/// [SectionPalette] gives a shared color per label and `sectionRuns` unfolds
/// `Measure.repeatStart`/`repeatEnd` into the played order (so `|: A :|` shows as
/// two A-runs in the minimap) — this detector only supplies the *written* markers.
///
/// Pure Dart (no Flutter imports) so it can be unit-tested off-device.
class SectionDetector {
  /// Fewer strains than this → no useful structure; return no sections (the
  /// minimap stays hidden, matching today's behavior for structureless tunes).
  static const _minStrains = 2;

  /// Candidate strain sizes (in bars) for tunes without explicit repeat brackets.
  static const _blockSizes = [8, 4];

  /// Strain boundaries come from, in order of trust: the author's part labels,
  /// repeat brackets, the author's ABC music lines, then equal 8/4-bar
  /// blocks. A boundary the author placed mid-bar (a `[P:X]` or a line that
  /// begins on a lead-in) is kept exactly; the rest start on a downbeat and
  /// are then moved back onto their lead-in by [withLeadIns].
  static List<Section> detect(List<Measure> measures) {
    final fromLabels = _fromPartLabels(measures);
    if (fromLabels != null) return withLeadIns(fromLabels, measures);

    final seg = _segment(measures);
    if (seg == null || seg.strains.length < _minStrains) return const [];
    final prints = [for (final s in seg.strains) _fingerprint(s)];
    final labels = _assignLabels(prints);
    return withLeadIns([
      for (var i = 0; i < seg.strains.length; i++)
        Section(
            label: labels[i],
            startMeasure: seg.starts[i],
            startNote: seg.startNotes?[i] ?? 0),
    ], measures);
  }

  /// [measures] with the authored line starts and part labels of [source]
  /// (the same tune converted afresh from its ABC), bar for bar. Unchanged
  /// unless the two still line up — the same bars with the same number of
  /// notes — since the hints are note positions and an edit can move them.
  static List<Measure> withAuthoredHints(
      List<Measure> measures, List<Measure> source) {
    if (source.length != measures.length) return measures;
    for (var i = 0; i < measures.length; i++) {
      if (source[i].notes.length != measures[i].notes.length) return measures;
    }
    return [
      for (var i = 0; i < measures.length; i++)
        Measure(
          number: measures[i].number,
          notes: measures[i].notes,
          hiddenLeadNotes: measures[i].hiddenLeadNotes,
          repeatStart: measures[i].repeatStart,
          repeatEnd: measures[i].repeatEnd,
          daCapo: measures[i].daCapo,
          dalSegno: measures[i].dalSegno,
          fine: measures[i].fine,
          toCoda: measures[i].toCoda,
          segno: measures[i].segno,
          coda: measures[i].coda,
          partLabel: source[i].partLabel,
          partLabelNote: source[i].partLabelNote,
          lineStartNote: source[i].lineStartNote,
        ),
    ];
  }

  // ── Lead-ins ────────────────────────────────────────────────────────────────

  /// Moves each section start back onto its LEAD-IN: the notes at the end of
  /// the bar before it that lead into the section the way the piece's opening
  /// pickup leads into the first. A strain that starts on an upbeat is found
  /// by bar-counting on its downbeat, but musically (and in the words, for a
  /// song) it begins on the upbeat — Along the Road to Gundagai's "Where the |
  /// gum-trees", "There's my | moth-er", "No more | will I roam", each the last
  /// beat of the bar before, just as "there's a | track" is the opening
  /// pickup. Starting the section there is what lets a section-aware staff
  /// open the line with it.
  ///
  /// Only a piece that HAS an opening pickup gets lead-ins, and a lead-in is
  /// never longer than that pickup. Within the previous bar it starts on the
  /// first sounding note after the phrase's END — a rest, a note held over
  /// from the bar before, or a note of half a bar or more (Gundagai's tied
  /// G, the rest in `A2 z2 B2c2`). With no such ending, it is the tail as
  /// long as the opening pickup, on a note boundary, skipping leading rests.
  /// The first section's lead-in is the opening pickup itself, so a first
  /// section starting on the bar after it moves back onto the pickup bar. Any
  /// section already off its downbeat is left alone, as is a start at a
  /// repeat boundary, unless the tail of the `:|` bar before it is the same
  /// music as the lead-in into that repeat (Devil's Dream's `e2`), which
  /// then serves both.
  static List<Section> withLeadIns(
      List<Section> sections, List<Measure> measures) {
    if (measures.length < 2 || sections.length < 2) return sections;
    final pickup = measures.first.actualUnits;
    final fullBar = _commonUnits(measures);
    if (pickup <= 0 || pickup >= fullBar) return sections;
    final indexOf = {
      for (var i = 0; i < measures.length; i++) measures[i].number: i,
    };
    final first = sections.reduce((a, b) =>
        (indexOf[a.startMeasure] ?? 0) <= (indexOf[b.startMeasure] ?? 0)
            ? a
            : b);
    return [
      for (final s in sections)
        if (identical(s, first))
          indexOf[s.startMeasure] == 1 && s.startNote == 0
              ? Section(label: s.label, startMeasure: measures.first.number)
              : s
        else if (s.startNote != 0)
          s
        else
          _leadIn(s, measures, indexOf, pickup, fullBar) ?? s,
    ];
  }

  static Section? _leadIn(Section s, List<Measure> measures,
      Map<int, int> indexOf, int pickup, int fullBar) {
    final i = indexOf[s.startMeasure];
    if (i == null || i == 0) return null;
    final here = measures[i], prev = measures[i - 1];
    if (here.repeatStart && !prev.repeatEnd) return null;
    if (prev.actualUnits != fullBar) return null;
    final afterEnd = _afterPhraseEnd(prev.notes, pickup, fullBar);
    if (afterEnd == _noLeadIn) return null;
    final j = afterEnd ?? _pickupTail(prev.notes, pickup);
    if (j == null) return null;
    if (prev.repeatEnd) {
      // The tail of a `:|` bar also leads back into the repeat. It is this
      // section's lead-in only when it is the same music as the lead-in into
      // that repeat, so a section layout can move the repeat to include it
      // (`movedRepeats`).
      final o = repeatTargetIndex(measures, i - 1);
      if (o <= 0 || !sameMusic(prev.notes.sublist(j), measures[o - 1].notes)) {
        return null;
      }
    }
    return Section(label: s.label, startMeasure: prev.number, startNote: j);
  }

  static int _units(NoteEvent n) => thirtySecondUnits(n.noteValue, n.dotted);

  /// [_afterPhraseEnd]'s answer when the bar itself ends the phrase.
  static const _noLeadIn = -1;

  /// The first sounding note after the last phrase ending in [notes], if what
  /// follows it is a lead-in no longer than [pickup]. [_noLeadIn] when nothing
  /// sounds after the ending (the bar ends on a rest or a long note, so the
  /// next phrase starts on the downbeat); null when there is no ending to go
  /// by, or too much follows it.
  static int? _afterPhraseEnd(List<NoteEvent> notes, int pickup, int fullBar) {
    var end = -1;
    for (var k = 0; k < notes.length; k++) {
      final n = notes[k];
      if (n.isChord) continue;
      if (n.isRest || n.tieStop || _units(n) * 2 >= fullBar) end = k;
    }
    if (end < 0) return null;
    var j = end + 1;
    while (j < notes.length && (notes[j].isChord || notes[j].isRest)) {
      j++;
    }
    if (j >= notes.length) return _noLeadIn;
    var tail = 0;
    for (var k = j; k < notes.length; k++) {
      if (!notes[k].isChord) tail += _units(notes[k]);
    }
    return tail <= pickup ? j : null;
  }

  /// The tail of [notes] as long as [pickup], from its first sounding note;
  /// null if no note boundary falls exactly there.
  static int? _pickupTail(List<NoteEvent> notes, int pickup) {
    var tail = 0;
    var j = notes.length;
    while (j > 0 && tail < pickup) {
      j--;
      if (!notes[j].isChord) tail += _units(notes[j]);
    }
    while (j > 0 && notes[j].isChord) {
      j--; // a chord's members start with its primary note
    }
    if (tail != pickup) return null;
    while (j < notes.length && notes[j].isRest) {
      j++;
    }
    if (j <= 0 || j >= notes.length) return null;
    return j;
  }

  /// The commonest bar length — a full bar, whatever the time signature.
  static int _commonUnits(List<Measure> measures) {
    final counts = <int, int>{};
    for (final m in measures) {
      counts[m.actualUnits] = (counts[m.actualUnits] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  // ── Authored part labels ────────────────────────────────────────────────────

  /// Sections taken directly from the tune's own authored part markers (e.g.
  /// ABC's inline `[P:A]`/`[P:B]`/`[P:C]`, carried through as MusicXML
  /// rehearsal marks — see [Measure.partLabel]). Trusted verbatim, with no
  /// fingerprint/heuristic guessing, whenever there are at least [_minStrains]
  /// of them: the author has already said exactly where the parts are, and a
  /// bar-count heuristic can only approximate that (see [_segment]'s tail
  /// tiling). Returns null (not "no sections") when there aren't enough to
  /// trust, so [detect] falls through to the heuristics below.
  static List<Section>? _fromPartLabels(List<Measure> measures) {
    final marks = [
      for (var i = 0; i < measures.length; i++)
        if (measures[i].partLabel != null && measures[i].partLabel!.isNotEmpty)
          i
    ];
    if (marks.length < _minStrains) return null;

    final sections = <Section>[];
    for (var k = 0; k < marks.length; k++) {
      final markIdx = marks[k];
      final nextMarkIdx = k + 1 < marks.length ? marks[k + 1] : measures.length;
      // A `[P:A]` marker commonly lands on a pickup just before the part's
      // own `|:` (abcjs attaches it wherever `[P:X]` sits in the source,
      // which is often right before the pickup notes leading into the
      // repeat). Anchor on the repeat start instead, when there is one
      // before the next marker: the pickup is only a lead-in, and
      // [withLeadIns] gives the opening one back to the first section.
      var anchor = markIdx;
      for (var i = markIdx; i < nextMarkIdx; i++) {
        if (measures[i].repeatStart) {
          anchor = i;
          break;
        }
      }
      // Otherwise a label the author put mid-bar, on the part's lead-in,
      // starts the section on that note.
      final m = measures[markIdx];
      final note = anchor == markIdx && m.partLabelNote < m.notes.length
          ? m.partLabelNote
          : 0;
      sections.add(Section(
          label: m.partLabel!,
          startMeasure: measures[anchor].number,
          startNote: note));
    }
    return sections;
  }

  // ── Segmentation (no authored labels) ───────────────────────────────────────

  /// Split the measures into strains. Primary signal: repeat brackets (each `|:`
  /// starts a strain). Fallback: equal blocks of 8 then 4 bars.
  static _Strains? _segment(
      List<Measure> measures) {
    if (measures.length < 2) return null;

    if (measures.any((m) => m.repeatStart || m.repeatEnd)) {
      // A `|:` begins each strain; an opening pickup before the first one
      // joins it in [withLeadIns].
      final marks = [
        for (var i = 0; i < measures.length; i++)
          if (measures[i].repeatStart) i,
      ];
      if (marks.isEmpty) return null; // nothing to anchor a strain on

      // Everything through the last `:|` is covered by a repeat-bracketed
      // strain above; a straight-through tail with no bracket of its own
      // (e.g. "AABC": A repeats, B and C don't) still needs splitting below.
      var lastRepeatEnd = -1;
      for (var i = measures.length - 1; i >= 0; i--) {
        if (measures[i].repeatEnd) {
          lastRepeatEnd = i;
          break;
        }
      }
      final bracketedEnd =
          lastRepeatEnd >= 0 ? lastRepeatEnd + 1 : measures.length;

      final strains = <List<Measure>>[];
      final starts = <int>[];
      for (var k = 0; k < marks.length; k++) {
        final s = marks[k];
        final e = k + 1 < marks.length ? marks[k + 1] : bracketedEnd;
        strains.add(measures.sublist(s, e));
        starts.add(measures[s].number);
      }

      if (bracketedEnd < measures.length) {
        final tail = _tileTail(measures.sublist(bracketedEnd));
        if (tail != null) {
          strains.addAll(tail.strains);
          starts.addAll(tail.starts);
        }
      }

      if (strains.length < 2) return null;
      return (strains: strains, starts: starts, startNotes: null);
    }

    final lines = _lineStrains(measures);
    if (lines != null) return lines;

    // No repeats: group into equal blocks, optionally dropping a one-measure
    // pickup, preferring 8-bar then 4-bar strains. Require ≥2 whole strains.
    for (final block in _blockSizes) {
      for (final drop in const [0, 1]) {
        if (drop >= measures.length) continue;
        final body = measures.sublist(drop);
        if (body.length >= block * 2 && body.length % block == 0) {
          final strains = <List<Measure>>[];
          final starts = <int>[];
          for (var i = 0; i < body.length; i += block) {
            final chunk = body.sublist(i, i + block);
            strains.add(chunk);
            starts.add(chunk.first.number);
          }
          return (strains: strains, starts: starts, startNotes: null);
        }
      }
    }
    return null;
  }

  /// One strain per authored ABC music line ([Measure.lineStartNote]), for a
  /// tune with no repeats to go by. A line that begins mid-bar starts its
  /// strain on that note: the author began the line on the phrase's lead-in
  /// (Amazing Grace's `…| D4` / `D2 | G4…`). The first strain starts on the
  /// first full bar, as with blocks; [withLeadIns] adds the opening pickup.
  /// Null unless there are at least [_minStrains] lines of two or more bars.
  static _Strains? _lineStrains(List<Measure> measures) {
    final fullBar = _commonUnits(measures);
    final first = measures.first.actualUnits < fullBar ? 1 : 0;
    final idx = <int>[first], notes = <int>[0];
    for (var i = first + 1; i < measures.length; i++) {
      final k = measures[i].lineStartNote;
      // Past the end means the marker drifted there in an edit; ignore it.
      if (k == null || k >= measures[i].notes.length) continue;
      idx.add(i);
      notes.add(k);
    }
    if (idx.length < _minStrains) return null;
    for (var k = 0; k < idx.length; k++) {
      final end = k + 1 < idx.length ? idx[k + 1] : measures.length;
      if (end - idx[k] < 2) return null;
    }
    // Each strain holds just its own notes, from its start note up to the
    // next strain's, for fingerprinting: a line that starts mid-bar shares
    // that bar with the line before. The first strain gets the opening
    // pickup, the counterpart of the lead-ins the others begin with.
    List<Measure> strain(int k) {
      final from = k == 0 ? 0 : idx[k];
      final to = k + 1 < idx.length ? idx[k + 1] : measures.length;
      final out = <Measure>[];
      for (var i = from; i < to; i++) {
        final m = measures[i];
        out.add(i == idx[k] && notes[k] > 0
            ? m.copyWithNotes(m.notes.sublist(notes[k]))
            : m);
      }
      if (k + 1 < idx.length && notes[k + 1] > 0) {
        final m = measures[to];
        out.add(m.copyWithNotes(m.notes.sublist(0, notes[k + 1])));
      }
      return out;
    }

    return (
      strains: [for (var k = 0; k < idx.length; k++) strain(k)],
      starts: [for (final i in idx) measures[i].number],
      startNotes: notes,
    );
  }

  /// Tiles a straight-through tail (no repeat brackets of its own) using a mix
  /// of [_blockSizes] (8-bar and 4-bar chunks), preferring the fewest chunks —
  /// e.g. 12 bars as one 8 + one 4, not three 4s. Unlike the repeat-free path
  /// above, which requires one uniform size across an entire piece, a tail
  /// can legitimately hold differently-sized parts (an 8-bar B next to a
  /// 4-bar C). Null if the tail can't be tiled exactly by these two sizes.
  static _Strains? _tileTail(
      List<Measure> tail) {
    final sizes = _tiling(tail.length);
    if (sizes == null) return null;
    final strains = <List<Measure>>[];
    final starts = <int>[];
    var i = 0;
    for (final size in sizes) {
      final chunk = tail.sublist(i, i + size);
      strains.add(chunk);
      starts.add(chunk.first.number);
      i += size;
    }
    return (strains: strains, starts: starts, startNotes: null);
  }

  /// Fewest-chunk tiling of [total] bars using [_blockSizes] (8 then 4), most
  /// 8-bar chunks first — e.g. 12 -> `[8, 4]`, not `[4, 4, 4]`. Null if
  /// [total] can't be tiled exactly by these two sizes (e.g. not a multiple
  /// of the smaller one).
  static List<int>? _tiling(int total) {
    if (total <= 0) return null;
    final big = _blockSizes.first, small = _blockSizes.last; // 8, 4
    for (var eights = total ~/ big; eights >= 0; eights--) {
      final remainder = total - eights * big;
      if (remainder % small != 0) continue;
      final fours = remainder ~/ small;
      return [
        for (var i = 0; i < eights; i++) big,
        for (var i = 0; i < fours; i++) small,
      ];
    }
    return null;
  }

  // ── Fingerprint + matching ──────────────────────────────────────────────────

  /// One token string per measure (its note sequence) so near-match can compare
  /// tails. Chord symbols and ornaments are already absent from the model, so the
  /// melodic content is pre-normalized.
  static List<String> _fingerprint(List<Measure> strain) => [
        for (final m in strain) [for (final n in m.notes) _noteToken(n)].join(','),
      ];

  static String _noteToken(NoteEvent n) => n.isRest
      ? 'R'
      : '${n.midiNumber}.${n.noteValue.index}.${n.dotted ? 1 : 0}';

  /// Greedy first-appearance labeling: A, B, C…; a strain matching an earlier one
  /// (exact or near) reuses its letter.
  static List<String> _assignLabels(List<List<String>> prints) {
    final known = <List<String>>[]; // one fingerprint per distinct label
    final labels = <String>[];
    for (final fp in prints) {
      var idx = -1;
      for (var i = 0; i < known.length; i++) {
        if (_matches(fp, known[i])) {
          idx = i;
          break;
        }
      }
      if (idx < 0) {
        idx = known.length;
        known.add(fp);
      }
      labels.add(String.fromCharCode(65 + idx)); // A, B, C, …
    }
    return labels;
  }

  /// Exact match, or "near" match: equal except the last ≤2 measures (with a
  /// length difference of at most 1) — catches a strain restated with a different
  /// ending/variation (the ABAA case).
  static bool _matches(List<String> a, List<String> b) {
    if (_listEq(a, b)) return true;
    if ((a.length - b.length).abs() > 1) return false;
    final n = math.min(a.length, b.length);
    if (n < 3) return false; // too short to fuzzy-match
    for (var i = 0; i < n - 2; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Strains with their start measure numbers and, when some start mid-bar, the
/// note each starts on (null means every one starts on its downbeat).
typedef _Strains = ({
  List<List<Measure>> strains,
  List<int> starts,
  List<int>? startNotes,
});

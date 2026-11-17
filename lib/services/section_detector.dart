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
  /// the piece's own seams (see [_passageStrains]: time and key changes, the
  /// end of a multi-bar rest), repeat brackets, the author's ABC music lines,
  /// double barlines, a scanned page's printed lines, then equal 8/4-bar
  /// blocks. A boundary the author placed mid-bar (a `[P:X]` or a line that
  /// begins on a lead-in) is kept exactly; the rest start on a downbeat and
  /// are then moved back onto their lead-in by [withLeadIns].
  static List<Section> detect(List<Measure> measures) {
    final fromLabels = _fromPartLabels(measures);
    if (fromLabels != null) return withLeadIns(fromLabels, measures);

    final seg = _passageStrains(measures) ?? _segment(measures);
    if (seg == null || seg.strains.length < _minStrains) return const [];
    // An opening of nothing but rests (an accompaniment's intro) is its own
    // section, but not a strain of the tune: it takes no letter.
    final intro = _allRests(seg.strains.first);
    final prints = [
      for (final s in intro ? seg.strains.skip(1) : seg.strains)
        _fingerprint(s)
    ];
    final labels = [if (intro) introLabel, ..._assignLabels(prints)];
    return withLeadIns([
      for (var i = 0; i < seg.strains.length; i++)
        Section(
            label: labels[i],
            startMeasure: seg.starts[i],
            startNote: seg.startNotes?[i] ?? 0),
    ], measures);
  }

  /// The label of an opening section that is all rests.
  static const introLabel = '-';

  static bool _allRests(List<Measure> strain) =>
      strain.every((m) => m.notes.every((n) => n.isRest));

  // ── Passages: the piece's own seams ─────────────────────────────────────────

  /// Bars a time change, key change or double bar must be from the boundary
  /// before it (and from the end) to start a passage of its own. Closer than
  /// this it is one seam written in stages — We Wish You a Merry Christmas
  /// Fantasy changes time, then two scale bars later key — and the first wins.
  static const _minPassageBars = 4;

  /// A passage this many counted bars or longer is a run of strains, not one,
  /// and is split further (its repeats, lines or 8-bar blocks).
  static const _splitPassageBars = 16;

  /// The bars at which a time or key change really changes something: not
  /// bar 1's, and not a signature restating the one in force (a score with
  /// no opening key is in C, as MusicXML reads it — scans write `0` out on a
  /// later line). A meter change must change the bar's length: 2/2 to 4/4 is
  /// what OMR makes of a cut-time C read as common time, not a new passage.
  static Set<int> _meterOrKeyChanges(List<Measure> measures) {
    final out = <int>{};
    var units = measures.first.timeChange?.units;
    var key = measures.first.keyChange ?? 0;
    for (var i = 1; i < measures.length; i++) {
      final t = measures[i].timeChange?.units, k = measures[i].keyChange;
      if ((t != null && units != null && t != units) ||
          (k != null && k != key)) {
        out.add(i);
      }
      units = t ?? units;
      key = k ?? key;
    }
    return out;
  }

  /// Passages between the seams a medley or fantasy is built on: a change of
  /// time or key, and the first note after a multi-bar rest (where the soloist
  /// comes in, on the very note — a pickup inside the bar included). Double
  /// barlines also count once one of those is present. A meter that lasts a
  /// single bar ends the phrase before it rather than starting one (a 2/4 bar
  /// between 4/4s): the passage starts where the meter settles. Seams closer
  /// than [_minPassageBars] keep only the first; the end of a rest is always
  /// kept. Null when there is no time, key or rest seam, so tunes without
  /// them go through [_segment] exactly as before.
  ///
  /// A rest run at the start becomes its own passage; each passage of
  /// [_splitPassageBars] or more is split again by [_splitPassage].
  static _Strains? _passageStrains(List<Measure> measures) {
    final n = measures.length;
    if (n < 2) return null;
    bool rests(Measure m) => m.notes.every((x) => x.isRest);

    // Multi-bar rests, and the first note after each.
    final inRest = List.filled(n, false);
    final restEnds = <({int bar, int note})>[];
    for (var i = 0; i < n;) {
      if (!rests(measures[i])) {
        i++;
        continue;
      }
      var j = i;
      while (j < n && rests(measures[j])) {
        j++;
      }
      if (j - i >= 2) {
        for (var k = i; k < j; k++) {
          inRest[k] = true;
        }
        if (j < n) {
          restEnds.add(
              (bar: j, note: measures[j].notes.indexWhere((x) => !x.isRest)));
        }
      }
      i = j;
    }

    final changes = _meterOrKeyChanges(measures);
    // A meter lasting one bar: the seam is the bar after it.
    final meterOf = _fullBars(measures);
    changes.removeWhere((i) =>
        changes.contains(i + 1) &&
        measures[i].timeChange != null &&
        meterOf[i] != meterOf[i + 1]);
    if (changes.isEmpty && restEnds.isEmpty) return null;

    final weak = {
      ...changes,
      for (var i = 0; i < n - 1; i++)
        if (measures[i].doubleBarEnd) i + 1,
    }..removeWhere((i) => inRest[i] || restEnds.any((r) => r.bar == i));
    final candidates = [
      for (final r in restEnds) (bar: r.bar, note: r.note, strong: true),
      for (final i in weak) (bar: i, note: 0, strong: false),
    ]..sort((a, b) => a.bar.compareTo(b.bar));

    final kept = <({int bar, int note})>[(bar: 0, note: 0)];
    for (final c in candidates) {
      if (!c.strong &&
          (c.bar - kept.last.bar < _minPassageBars ||
              n - c.bar < _minPassageBars)) {
        continue;
      }
      if (c.bar == kept.last.bar && c.note == kept.last.note) continue;
      if (c.bar == 0 && c.note == 0) continue;
      kept.add((bar: c.bar, note: c.note));
    }
    if (kept.length < _minStrains) return null;

    final strains = <List<Measure>>[];
    final starts = <int>[], startNotes = <int>[];
    for (var k = 0; k < kept.length; k++) {
      final from = kept[k];
      final to = k + 1 < kept.length ? kept[k + 1] : (bar: n, note: 0);
      for (final p in _splitPassage(measures, from, to)) {
        strains.add(_slice(measures, p.from, p.to));
        starts.add(measures[p.from.bar].number);
        startNotes.add(p.from.note);
      }
    }
    return (strains: strains, starts: starts, startNotes: startNotes);
  }

  /// The notes from [from] up to (not including) [to], bar by bar: a passage
  /// that starts or ends mid-bar shares that bar with its neighbour.
  static List<Measure> _slice(List<Measure> measures, ({int bar, int note}) from,
      ({int bar, int note}) to) {
    final out = <Measure>[];
    for (var i = from.bar; i < to.bar; i++) {
      final m = measures[i];
      out.add(i == from.bar && from.note > 0
          ? m.copyWithNotes(m.notes.sublist(from.note))
          : m);
    }
    if (to.note > 0 && to.bar < measures.length) {
      final m = measures[to.bar];
      out.add(m.copyWithNotes(m.notes.sublist(0, to.note)));
    }
    return out;
  }

  /// One passage, split into strains when it has [_splitPassageBars] counted
  /// bars or more: by its own repeats, authored lines or evenly printed lines
  /// when those give two or more, else into 8-bar blocks from its first full
  /// bar, a remainder under 4 bars joining the last block. Strains after the
  /// first start on a downbeat, for [withLeadIns] to move onto their lead-ins.
  static List<({({int bar, int note}) from, ({int bar, int note}) to})>
      _splitPassage(List<Measure> measures, ({int bar, int note}) from,
          ({int bar, int note}) to) {
    final whole = [(from: from, to: to)];
    final first = from.note > 0 ? from.bar + 1 : from.bar;
    final count = to.bar - first;
    if (count < _splitPassageBars) return whole;
    final body = measures.sublist(first, to.bar);
    final seg =
        _repeatStrains(body) ?? _lineStrains(body) ?? _printedLineStrains(body);
    final cuts = <int>[];
    if (seg != null && seg.strains.length >= _minStrains) {
      final byNumber = {
        for (var i = first; i < to.bar; i++) measures[i].number: i,
      };
      for (var k = 1; k < seg.starts.length; k++) {
        if ((seg.startNotes?[k] ?? 0) != 0) return whole; // keep it simple
        cuts.add(byNumber[seg.starts[k]]!);
      }
    } else {
      for (var b = first + 8; to.bar - b >= _minPassageBars; b += 8) {
        cuts.add(b);
      }
    }
    final points = [from, for (final c in cuts) (bar: c, note: 0), to];
    return [
      for (var k = 0; k + 1 < points.length; k++)
        (from: points[k], to: points[k + 1]),
    ];
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
          doubleBarEnd: measures[i].doubleBarEnd,
          daCapo: measures[i].daCapo,
          dalSegno: measures[i].dalSegno,
          fine: measures[i].fine,
          toCoda: measures[i].toCoda,
          segno: measures[i].segno,
          coda: measures[i].coda,
          partLabel: source[i].partLabel,
          partLabelNote: source[i].partLabelNote,
          lineStartNote: source[i].lineStartNote,
          systemStart: measures[i].systemStart,
          timeChange: measures[i].timeChange,
          keyChange: measures[i].keyChange,
          endings: measures[i].endings,
        ),
    ];
  }

  // ── Lead-ins ────────────────────────────────────────────────────────────────

  /// Moves each section start back onto its LEAD-IN: the notes at the end of
  /// the bar before it that lead into the section the way the piece's opening
  /// pickup leads into the first. A strain that starts on an upbeat is found
  /// by bar-counting on its downbeat, but musically (and in the words, for a
  /// song) it begins on the upbeat: a new strain's words usually start on the
  /// last beat of the bar before, just as the opening pickup's do. Starting the
  /// section there is what lets a section-aware staff open the line with it.
  ///
  /// Only a piece that HAS an opening pickup gets lead-ins. Within the
  /// previous bar a lead-in starts on the first sounding note after the
  /// phrase's END — a rest, a note held over from the bar before, or a note
  /// of half a bar or more (Gundagai's tied G, the rest in `A2 z2 B2c2`) —
  /// however much of the bar that leaves: a song's lead-in is as long as its
  /// words, and Gundagai's run to three beats against a half-beat opening
  /// pickup. With no such ending, it is the tail as long as the opening
  /// pickup, on a note boundary, skipping leading rests.
  /// The first section's lead-in is the opening pickup itself, so a first
  /// section starting on the bar after it moves back onto the pickup bar.
  /// The opening pickup is the music before the first full bar: a short
  /// first bar, or the notes after the rests in the bar a soloist comes in
  /// on after a multi-bar rest (see [_openingPickup]). Any
  /// section already off its downbeat is left alone, as is one where the time
  /// or key changes (the new meter or key is where it begins), and a start at
  /// a repeat boundary, unless the tail of the `:|` bar before it is the same
  /// music as the lead-in into that repeat (Devil's Dream's `e2`), which
  /// then serves both.
  static List<Section> withLeadIns(
      List<Section> sections, List<Measure> measures) {
    if (measures.length < 2 || sections.length < 2) return sections;
    final opening = _openingPickup(measures);
    if (opening == null) return sections;
    final full = _fullBars(measures);
    final changes = _meterOrKeyChanges(measures);
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
          indexOf[s.startMeasure] == opening.bar + 1 && s.startNote == 0
              ? Section(
                  label: s.label,
                  startMeasure: measures[opening.bar].number,
                  startNote: opening.note)
              : s
        else if (s.startNote != 0 || changes.contains(indexOf[s.startMeasure]))
          s
        else
          _leadIn(s, measures, indexOf, opening.units, full) ?? s,
    ];
  }

  static Section? _leadIn(Section s, List<Measure> measures,
      Map<int, int> indexOf, int pickup, List<int> full) {
    final i = indexOf[s.startMeasure];
    if (i == null || i == 0) return null;
    final here = measures[i], prev = measures[i - 1];
    if (here.repeatStart && !prev.repeatEnd) return null;
    if (prev.actualUnits != full[i - 1]) return null;
    final afterEnd = _afterPhraseEnd(prev.notes, full[i - 1]);
    if (afterEnd == _noLeadIn) return null;
    var j = afterEnd ?? _pickupTail(prev.notes, pickup);
    if (j == null) return null;
    if (prev.repeatEnd) {
      // The tail of a `:|` bar also leads back into the repeat. It is this
      // section's lead-in only when it is the same music as the lead-in into
      // that repeat, so a section layout can move the repeat to include it
      // (`movedRepeats`). Failing that after the phrase's end, the
      // pickup-length tail may be (Galopede's `A4 A2 dc :|`, whose `dc` is).
      final o = repeatTargetIndex(measures, i - 1);
      if (o <= 0) return null;
      bool leadsBack(int k) =>
          sameMusic(prev.notes.sublist(k), measures[o - 1].notes);
      if (!leadsBack(j)) {
        final t = afterEnd == null ? null : _pickupTail(prev.notes, pickup);
        if (t == null || !leadsBack(t)) return null;
        j = t;
      }
    }
    return Section(label: s.label, startMeasure: prev.number, startNote: j);
  }

  static int _units(NoteEvent n) => thirtySecondUnits(n.noteValue, n.dotted);

  /// [_afterPhraseEnd]'s answer when the bar itself ends the phrase.
  static const _noLeadIn = -1;

  /// The first sounding note after the last phrase ending in [notes].
  /// [_noLeadIn] when nothing sounds after the ending (the bar ends on a rest
  /// or a long note, so the next phrase starts on the downbeat); null when
  /// there is no ending to go by.
  static int? _afterPhraseEnd(List<NoteEvent> notes, int fullBar) {
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
    return j >= notes.length ? _noLeadIn : j;
  }

  /// The tail of [notes] as long as [pickup], from its first sounding note;
  /// null if no note boundary falls exactly there.
  static int? _pickupTail(List<NoteEvent> notes, int pickup) {
    // Exact lengths, so a pickup of triplets matches the bar it completes.
    var tail = 0.0;
    var j = notes.length;
    while (j > 0 && tail < pickup - 1e-6) {
      j--;
      if (!notes[j].isChord) tail += notes[j].units;
    }
    while (j > 0 && notes[j].isChord) {
      j--; // a chord's members start with its primary note
    }
    if ((tail - pickup).abs() > 1e-6) return null;
    while (j < notes.length && notes[j].isRest) {
      j++;
    }
    if (j <= 0 || j >= notes.length) return null;
    return j;
  }

  /// The opening pickup: where it starts and how long it is. A short first
  /// bar is one (from its start, as ever); so are the notes after the rests
  /// in the first bar that sounds after leading rest bars — a solo part
  /// coming in on an upbeat after an accompaniment's intro. Null when the
  /// music starts on a full bar's downbeat.
  static ({int bar, int note, int units})? _openingPickup(
      List<Measure> measures) {
    final full = _fullBars(measures);
    final f = measures.indexWhere((m) => m.notes.any((n) => !n.isRest));
    if (f < 0) return null;
    if (f == 0) {
      final units = measures.first.actualUnits;
      return units > 0 && units < full[0]
          ? (bar: 0, note: 0, units: units)
          : null;
    }
    final notes = measures[f].notes;
    final k = notes.indexWhere((n) => !n.isRest);
    final units = unitsOf(notes.sublist(k));
    return units > 0 && units < full[f] ? (bar: f, note: k, units: units) : null;
  }

  /// Each bar's full length: the commonest bar length, or, in a piece that
  /// changes meter, the length of the meter in force there.
  static List<int> _fullBars(List<Measure> measures) {
    final common = _commonUnits(measures);
    final meters = {
      for (final m in measures)
        if (m.timeChange != null) m.timeChange!,
    };
    if (meters.length < 2) return List.filled(measures.length, common);
    var cur = measures.first.timeChange?.units ?? common;
    return [for (final m in measures) cur = m.timeChange?.units ?? cur];
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
  /// starts a strain); then authored ABC lines, double barlines and a scan's
  /// printed lines. Fallback: equal blocks of 8 then 4 bars.
  static _Strains? _segment(
      List<Measure> measures) {
    if (measures.length < 2) return null;
    final repeats = _repeatStrains(measures);
    if (repeats != null) return repeats;

    final lines = _lineStrains(measures);
    if (lines != null) return lines;

    final doubleBars = _doubleBarStrains(measures);
    if (doubleBars != null) return doubleBars;

    final printed = _printedLineStrains(measures);
    if (printed != null) return printed;

    return _blockStrains(measures);
  }

  /// The strains repeat brackets mark out: a `|:` begins each one. A `:|` with
  /// no `|:` before it goes back to the start (as [repeatTargetIndex] plays
  /// it), so it begins one there — on the first full bar, exactly where a
  /// written `|:` would sit after an opening pickup. Null when the brackets
  /// give fewer than [_minStrains] (one repeat round the whole piece, either
  /// way it is written), so the other signals get their turn.
  static _Strains? _repeatStrains(List<Measure> measures) {
    if (!measures.any((m) => m.repeatStart || m.repeatEnd)) return null;
    // A `|:` begins each strain; an opening pickup before the first one
    // joins it in [withLeadIns].
    final marks = [
      for (var i = 0; i < measures.length; i++)
        if (measures[i].repeatStart) i,
    ];
    final firstEnd = measures.indexWhere((m) => m.repeatEnd);
    if (firstEnd >= 0 && (marks.isEmpty || marks.first > firstEnd)) {
      final first =
          measures.first.actualUnits < _commonUnits(measures) ? 1 : 0;
      if (first <= firstEnd) marks.insert(0, first);
    }
    if (marks.isEmpty) return null;

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

    if (strains.length < _minStrains) return null;
    return (strains: strains, starts: starts, startNotes: null);
  }

  /// Equal blocks of bars, for a tune with nothing else to go by.
  static _Strains? _blockStrains(List<Measure> measures) {
    // No repeats: group into equal blocks of counted bars (lead-ins left out,
    // see [_leadInBars]), preferring 8-bar then 4-bar strains. Require ≥2
    // whole strains.
    final leadIns = _leadInBars(measures);
    final counted = [
      for (var i = 0; i < measures.length; i++)
        if (!leadIns.contains(i)) i,
    ];
    for (final block in _blockSizes) {
      if (counted.length >= block * 2 && counted.length % block == 0) {
        final strains = <List<Measure>>[];
        final starts = <int>[];
        _addBlocks(measures, leadIns, counted,
            [for (var k = 0; k < counted.length; k += block) block],
            strains, starts);
        return (strains: strains, starts: starts, startNotes: null);
      }
    }

    // Otherwise the same, optionally dropping a one-measure pickup.
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

  /// The strains between double barlines ([Measure.doubleBarEnd]), for a
  /// tune with no repeats or authored lines to go by: a song's verse and
  /// chorus. Each passage is tiled into 8- and 4-bar strains when its counted
  /// bars allow (see [_tiling]), else kept whole. Null unless a bar before
  /// the last has a double bar and that yields [_minStrains] strains.
  static _Strains? _doubleBarStrains(List<Measure> measures) {
    final ends = [
      for (var i = 0; i < measures.length - 1; i++)
        if (measures[i].doubleBarEnd) i,
    ];
    if (ends.isEmpty) return null;
    final leadIns = _leadInBars(measures);
    final strains = <List<Measure>>[];
    final starts = <int>[];
    var from = 0;
    for (final end in [...ends, measures.length - 1]) {
      final counted = [
        for (var i = from; i <= end; i++)
          if (!leadIns.contains(i)) i,
      ];
      from = end + 1;
      if (counted.isEmpty) continue;
      _addBlocks(measures, leadIns, counted,
          _tiling(counted.length) ?? [counted.length], strains, starts);
    }
    if (strains.length < _minStrains) return null;
    return (strains: strains, starts: starts, startNotes: null);
  }

  /// One strain per printed line ([Measure.systemStart]) of a scanned page,
  /// when every line holds the same 4 or 8 counted bars — a page laid out a
  /// phrase to a line, as beginner method books are (O Come Little Children's four
  /// lines). Irregular lines are only where the page ran out (Perpetual
  /// Motion's three-bar lines) and are ignored. Lines break at barlines, so
  /// each strain starts on its downbeat and [withLeadIns] moves it onto its
  /// lead-in, as for blocks.
  static _Strains? _printedLineStrains(List<Measure> measures) {
    final breaks = [
      for (var i = 1; i < measures.length; i++)
        if (measures[i].systemStart) i,
    ];
    if (breaks.length + 1 < _minStrains) return null;
    final leadIns = _leadInBars(measures);
    final counted = [
      for (var i = 0; i < measures.length; i++)
        if (!leadIns.contains(i)) i,
    ];
    final sizes = <int>[];
    var from = 0;
    for (final end in [...breaks, measures.length]) {
      sizes.add(counted.where((i) => i >= from && i < end).length);
      from = end;
    }
    if (sizes.toSet().length != 1 || !_blockSizes.contains(sizes.first)) {
      return null;
    }
    final strains = <List<Measure>>[];
    final starts = <int>[];
    _addBlocks(measures, leadIns, counted, sizes, strains, starts);
    return (strains: strains, starts: starts, startNotes: null);
  }

  /// LEAD-IN bars: short bars that open a phrase rather than end one, so
  /// they aren't counted when strains are measured in bars. The opening
  /// pickup, and the second of two short bars that make one full bar between
  /// them — a score splitting a bar at a section break, its first half ending
  /// one section and its second the next one's pickup (Gundagai's `A z ‖ d c`,
  /// The Single Girl's `…G2 ‖ G`).
  static Set<int> _leadInBars(List<Measure> measures) {
    final full = _fullBars(measures);
    return {
      for (var i = 0; i < measures.length; i++)
        if (measures[i].actualUnits < full[i] &&
            (i == 0 ||
                (measures[i - 1].actualUnits < full[i] &&
                    measures[i - 1].actualUnits + measures[i].actualUnits ==
                        full[i])))
          i,
    };
  }

  /// Appends one strain per entry of [sizes], taking that many of the
  /// [counted] bars in turn. A strain starts on the lead-in bar before its
  /// first counted bar when there is one; the lead-in is left out of the
  /// strain itself, so it doesn't decide whether two strains match.
  static void _addBlocks(
      List<Measure> measures,
      Set<int> leadIns,
      List<int> counted,
      List<int> sizes,
      List<List<Measure>> strains,
      List<int> starts) {
    var k = 0;
    for (final size in sizes) {
      final first = counted[k];
      final start = leadIns.contains(first - 1) ? first - 1 : first;
      strains.add([for (final i in counted.sublist(k, k + size)) measures[i]]);
      starts.add(measures[start].number);
      k += size;
    }
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
  /// tails. A token is pitch, note value and dot only, so chord symbols
  /// (`NoteEvent.chordSymbol`) and ornaments never enter the comparison.
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

  /// Exact match, or "near" match: equal except an ENDING (with a length
  /// difference of at most 1) — a strain restated with a different ending, as
  /// with first and second endings (the ABAA case). The ending is the last 2
  /// bars, or 3/8 of a longer strain: Gundagai's last chorus strain is its
  /// first one's opening five bars, then `c B.` for `c B G` and a final rest
  /// for the lead-in into the next strain.
  static bool _matches(List<String> a, List<String> b) {
    if (_listEq(a, b)) return true;
    if ((a.length - b.length).abs() > 1) return false;
    final n = math.min(a.length, b.length);
    if (n < 3) return false; // too short to fuzzy-match
    final ending = math.max(2, n * 3 ~/ 8);
    for (var i = 0; i < n - ending; i++) {
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

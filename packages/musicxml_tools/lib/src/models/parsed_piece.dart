import 'clef.dart';
import 'note_event.dart';
import 'transpose.dart';

/// A time signature: [beats] of [beatType] notes per bar.
class Meter {
  final int beats;
  final int beatType;
  const Meter(this.beats, this.beatType);

  /// A full bar's length in 32nd-note units.
  int get units => beats * 32 ~/ beatType;

  @override
  bool operator ==(Object other) =>
      other is Meter && other.beats == beats && other.beatType == beatType;

  @override
  int get hashCode => Object.hash(beats, beatType);

  @override
  String toString() => '$beats/$beatType';
}

class Measure {
  final int number;
  final List<NoteEvent> notes;
  final List<NoteEvent> hiddenLeadNotes;

  /// Repeat barlines on this measure's boundaries, parsed from MusicXML
  /// `<barline><repeat direction="forward|backward"/>`. [repeatStart] is the
  /// forward repeat on the left edge (`|:`); [repeatEnd] is the backward repeat
  /// on the right edge (`:|`, drawn as the doubled light-heavy barline).
  final bool repeatStart;
  final bool repeatEnd;

  /// A double barline (`||`) on this measure's right edge, not a repeat: the
  /// light-light of a score's section break, or the heavy-heavy an OMR scan
  /// reads a thick one as. A section boundary for [SectionDetector], and the
  /// place a printed score may split a bar between a section's end and the
  /// next one's pickup.
  final bool doubleBarEnd;

  /// Navigation marks, parsed from MusicXML `<sound>` attributes (and the
  /// `<segno/>` symbol, and "D.C."/"D.S."/"Fine" words when a score has only
  /// the text). All act at this measure's END except [segno] and [coda],
  /// which mark where a jump lands — see [ParsedPiece.performanceOrder].
  ///  * [daCapo] — `D.C.`: back to the start.
  ///  * [dalSegno] — `D.S.`: back to the [segno].
  ///  * [fine] — after a D.C./D.S., the piece ends here.
  ///  * [toCoda] — after a D.C./D.S., skip ahead to the [coda].
  final bool daCapo;
  final bool dalSegno;
  final bool fine;
  final bool toCoda;
  final bool segno;
  final bool coda;

  /// This measure's authored part label (e.g. `'A'`, `'B'`), parsed from a
  /// MusicXML `<direction><rehearsal>` — how an ABC tune's own inline
  /// `[P:A]`/`[P:B]`/`[P:C]` markers survive the conversion (see
  /// abc_to_musicxml.js). Null on every measure that isn't where a part
  /// starts/changes. [SectionDetector] trusts these directly, with no
  /// fingerprint guessing, whenever a piece has enough of them.
  final String? partLabel;

  /// Where in [notes] the [partLabel] sits: 0 at the bar start, more when the
  /// author put `[P:X]` mid-bar, on the part's lead-in.
  final int partLabelNote;

  /// Index into [notes] where an authored ABC music line begins in this
  /// measure (0 at the bar start, more when the line starts mid-bar, on a
  /// lead-in), or null if none does. A phrase-start hint for
  /// [SectionDetector]; see abc_to_musicxml.js.
  final int? lineStartNote;

  /// This measure opens a printed line: a `<print new-system="yes">` in the
  /// stored score: an OMR scan writes them, and several bundled scores carry
  /// them from their source encoding (the page's own layout; the app adds
  /// its line breaks to the engrave copy, never the file). A
  /// phrase-start hint for [SectionDetector].
  final bool systemStart;

  /// The time signature written in this measure (a `<time>` in its
  /// `<attributes>`): where the meter changes. Null on every bar that carries
  /// on in the meter before it. The meter in force for any bar is
  /// [ParsedPiece.meterAt].
  final Meter? timeChange;

  /// The key signature written in this measure (the `<fifths>` of a `<key>`
  /// in its `<attributes>`), or null when it carries on in the key before it.
  /// Like [timeChange], it may restate the key in force; compare before
  /// treating it as a change. A section boundary for [SectionDetector].
  final int? keyChange;

  /// The volta brackets ("first/second endings") this measure sits under,
  /// parsed from MusicXML `<ending>` elements in the measures' barlines (a
  /// `start` opens a bracket, a `stop` or `discontinue` closes it): `{1}`
  /// under a first ending, `{2}` under a second,
  /// `{1, 2}` for a bracket numbered `1, 2`. Empty for an ordinary measure.
  /// [ParsedPiece.performanceOrder] plays a measure only on the passes its
  /// set names.
  final Set<int> endings;

  const Measure({
    required this.number,
    required this.notes,
    this.hiddenLeadNotes = const [],
    this.repeatStart = false,
    this.repeatEnd = false,
    this.doubleBarEnd = false,
    this.daCapo = false,
    this.dalSegno = false,
    this.fine = false,
    this.toCoda = false,
    this.segno = false,
    this.coda = false,
    this.partLabel,
    this.partLabelNote = 0,
    this.lineStartNote,
    this.systemStart = false,
    this.timeChange,
    this.keyChange,
    this.endings = const {},
  });

  /// Returns a copy with replaced [notes], carrying the measure number, hidden
  /// pickup rests, repeat and navigation flags, part label and line start through unless explicitly
  /// overridden. The jianpu/fingering processors rebuild measures via this
  /// method, so all of that must survive to `parsedPieceProvider`'s output.
  Measure copyWithNotes(List<NoteEvent> notes,
          {bool? repeatStart, bool? repeatEnd}) =>
      Measure(
        number: number,
        notes: notes,
        hiddenLeadNotes: hiddenLeadNotes,
        repeatStart: repeatStart ?? this.repeatStart,
        repeatEnd: repeatEnd ?? this.repeatEnd,
        doubleBarEnd: doubleBarEnd,
        daCapo: daCapo,
        dalSegno: dalSegno,
        fine: fine,
        toCoda: toCoda,
        segno: segno,
        coda: coda,
        partLabel: partLabel,
        partLabelNote: partLabelNote,
        lineStartNote: lineStartNote,
        systemStart: systemStart,
        timeChange: timeChange,
        keyChange: keyChange,
        endings: endings,
      );

  /// True when this measure's visible notes don't sum to the expected number of
  /// beats — a common OMR symptom (a note split in two, or two merged). Pickup
  /// measures (number 0) are intentionally never flagged, since they are
  /// expected to be short. Compares in 32nd-note units to stay integer-exact.
  bool isDurationMismatch(int beatsPerMeasure, int beatType) {
    if (number == 0) return false;
    final expected = beatsPerMeasure * 32 ~/ beatType;
    return actualUnits != expected;
  }

  /// Sum of this measure's visible-note durations in 32nd-note units.
  ///
  /// Chord members ([NoteEvent.isChord] — the 2nd+ note on one stem) are skipped:
  /// they sound at the primary note's onset and occupy no time of their own, so
  /// counting them would inflate the bar and falsely flag it (a two-note chord
  /// of quarters in 4/4 would read as 5 beats, not 4).
  ///
  /// Tuplets count at their real length: three triplet eighths are a quarter.
  int get actualUnits => unitsOf(notes);

  /// True when this measure is shorter than a full bar — the hallmark of a
  /// pickup/anacrusis.
  bool isShort(int beatsPerMeasure, int beatType) =>
      actualUnits < beatsPerMeasure * 32 ~/ beatType;
}

class ParsedPiece {
  final String keySignature;
  final int keyFifths;
  final KeyMode keyMode;
  final List<Measure> measures;

  /// Timing metadata from the first `<attributes>` block. Needed to generate
  /// `<duration>` values when serializing edits and to validate beat counts.
  /// Defaults match a 4/4 score with one division per quarter note.
  final int divisions;

  /// The OPENING meter. A piece may change meter: each bar's own is
  /// [meterAt], from the [Measure.timeChange]s — use that for anything about
  /// a particular bar (its beat count, a count-in starting there).
  final int beatsPerMeasure;
  final int beatType;

  /// The tempo the score itself asks for, in quarter notes per minute (the
  /// unit [MidiGenerator] plays in), or null when it marks none. The default
  /// performance tempo when nothing more particular is known.
  final double? markedBpm;

  /// The clef the first part opens in: its first `<clef>`. Null when the
  /// score writes none. Later clef changes are not modelled.
  final Clef? openingClef;

  /// The first part's opening `<transpose>`, sounding minus written. Null
  /// when the part is written at concert pitch (no `<transpose>`).
  final Transpose? openingTranspose;

  const ParsedPiece({
    required this.keySignature,
    required this.keyFifths,
    required this.keyMode,
    required this.measures,
    this.divisions = 1,
    this.beatsPerMeasure = 4,
    this.beatType = 4,
    this.markedBpm,
    this.openingClef,
    this.openingTranspose,
  });

  /// The same music with the meter change at document index [index] set to
  /// [meter], or removed when [meter] is null — the measure editor's "what if
  /// the meter changed to 4/4 here?", asked before anything is written so it
  /// can show which bars would add up. At index 0 [meter] is the opening
  /// meter, which can't be removed (a null there changes nothing).
  ParsedPiece copyWithTimeChangeAt(int index, Meter? meter) {
    if (index <= 0) {
      if (meter == null || measures.isEmpty) return this;
      final opening = measures[0].timeChange != null
          ? [_withTimeChange(measures[0], meter), ...measures.skip(1)]
          : measures;
      return ParsedPiece(
        keySignature: keySignature,
        keyFifths: keyFifths,
        keyMode: keyMode,
        measures: opening,
        divisions: divisions,
        beatsPerMeasure: meter.beats,
        beatType: meter.beatType,
        markedBpm: markedBpm,
        openingClef: openingClef,
        openingTranspose: openingTranspose,
      );
    }
    return copyWithMeasures([
      for (var i = 0; i < measures.length; i++)
        i == index ? _withTimeChange(measures[i], meter) : measures[i],
    ]);
  }

  /// Document indices of the bars whose meter is set at [index]: from it up
  /// to (not including) the next [Measure.timeChange].
  Iterable<int> meterSpanFrom(int index) sync* {
    for (var k = index; k < measures.length; k++) {
      if (k > index && measures[k].timeChange != null) return;
      yield k;
    }
  }

  static Measure _withTimeChange(Measure m, Meter? meter) => Measure(
        number: m.number,
        notes: m.notes,
        hiddenLeadNotes: m.hiddenLeadNotes,
        repeatStart: m.repeatStart,
        repeatEnd: m.repeatEnd,
        doubleBarEnd: m.doubleBarEnd,
        daCapo: m.daCapo,
        dalSegno: m.dalSegno,
        fine: m.fine,
        toCoda: m.toCoda,
        segno: m.segno,
        coda: m.coda,
        partLabel: m.partLabel,
        partLabelNote: m.partLabelNote,
        lineStartNote: m.lineStartNote,
        systemStart: m.systemStart,
        timeChange: meter,
        keyChange: m.keyChange,
        endings: m.endings,
      );

  /// The meter the piece opens in: [beatsPerMeasure]/[beatType].
  Meter get openingMeter => Meter(beatsPerMeasure, beatType);

  /// The meter in force for every measure, by document index: the opening
  /// meter until the first [Measure.timeChange], then each change until the
  /// next. One list per call, so callers walking the whole piece should take
  /// it once rather than ask [meterAt] per bar.
  List<Meter> get meters {
    var current = openingMeter;
    return [
      for (final m in measures) current = m.timeChange ?? current,
    ];
  }

  /// The meter in force at document index [index] (clamped to the piece).
  Meter meterAt(int index) {
    if (measures.isEmpty) return openingMeter;
    final i = index.clamp(0, measures.length - 1);
    for (var k = i; k >= 0; k--) {
      final t = measures[k].timeChange;
      if (t != null) return t;
    }
    return openingMeter;
  }

  /// The meter in force at the measure numbered [number] — the opening meter
  /// if no measure has that number.
  Meter meterAtNumber(int number) {
    final i = measures.indexWhere((m) => m.number == number);
    return i < 0 ? openingMeter : meterAt(i);
  }

  /// The key (`<fifths>`) in force at document index [index] (clamped to the
  /// piece): [keyFifths] until the first [Measure.keyChange], then each
  /// change until the next.
  int keyAt(int index) {
    if (measures.isEmpty) return keyFifths;
    final i = index.clamp(0, measures.length - 1);
    for (var k = i; k >= 0; k--) {
      final f = measures[k].keyChange;
      if (f != null) return f;
    }
    return keyFifths;
  }

  /// Document indices of the bars whose key is set at [index]: from it up to
  /// (not including) the next [Measure.keyChange].
  Iterable<int> keySpanFrom(int index) sync* {
    for (var k = index; k < measures.length; k++) {
      if (k > index && measures[k].keyChange != null) return;
      yield k;
    }
  }

  /// Whether the meter changes anywhere after the opening.
  bool get hasMeterChanges {
    final all = meters;
    return all.any((m) => m != all.first);
  }

  ParsedPiece copyWithMeasures(List<Measure> measures) => ParsedPiece(
        keySignature: keySignature,
        keyFifths: keyFifths,
        keyMode: keyMode,
        measures: measures,
        divisions: divisions,
        beatsPerMeasure: beatsPerMeasure,
        beatType: beatType,
        markedBpm: markedBpm,
        openingClef: openingClef,
        openingTranspose: openingTranspose,
      );

  List<NoteEvent> get allNotes =>
      measures.expand((m) => m.notes).toList(growable: false);

  /// The highest lyric verse number on any note — 0 for a piece with no lyrics.
  int get verseCount {
    var n = 0;
    for (final m in measures) {
      for (final note in m.notes) {
        for (final v in note.lyrics.keys) {
          if (v > n) n = v;
        }
      }
    }
    return n;
  }

  /// Document-measure indices in performance order, honoring simple forward/
  /// backward repeats. A forward repeat ([Measure.repeatStart]) sets the return
  /// point; a backward repeat ([Measure.repeatEnd]), the first time it's
  /// reached, jumps back to that return point once (defaulting to the piece
  /// start if no forward repeat preceded it), then continues past on the second
  /// arrival. Nested repeats are out of scope. With no repeats the result is
  /// the identity `[0, 1, … n-1]`.
  ///
  /// First/second endings ([Measure.endings]) are honoured by counting
  /// passes: each `:|` taken starts the next pass, and a measure under a
  /// volta plays only on the passes it names, so `|: 1–3 [1 4 :| [2 5` plays
  /// 1 2 3 4 1 2 3 5. A first ending with no `:|` of its own (OMR missed it,
  /// or nobody marked one) repeats anyway when the next measure is an ending
  /// for a later pass. Once a volta group is behind it, a later `:|` with no
  /// `|:` returns to the bar after the group, not to the earlier strain.
  ///
  /// Then the navigation marks: at the end of a [Measure.daCapo] (or
  /// [Measure.dalSegno]) bar — once its own `:|`, if any, has been taken — the
  /// one jump goes back to the start (or the last [Measure.segno] before it).
  /// On that pass every repeat already taken falls straight through, the
  /// usual reading of a D.C., and a [Measure.fine] ends the piece or a
  /// [Measure.toCoda] skips to the next [Measure.coda]. Before the jump, Fine
  /// and To Coda are ignored. Gossec's Gavotte, `|: 1–8 :| 9–16 Fine |: 17–24
  /// :| |: 25–32 :| D.C. al Fine`, plays 1–8 1–8 9–16 17–24 17–24 25–32 25–32
  /// 1–8 9–16.
  ///
  /// Shared by MIDI generation (audio order) and the section-organized layout /
  /// staff unfold (so a `|: A :|` span shows up as two `A`s on the staff).
  static List<int> performanceOrder(List<Measure> measures) =>
      _unfold(measures).order;

  /// The D.C./D.S. jump, if the piece has one: [perfIndex] is the position in
  /// [performanceOrder] of the first bar played after it, and [label] is
  /// the instruction as a player reads it (`D.C.`, `D.S. al Fine`,
  /// `D.C. al Coda`). Null when nothing jumps. The section bar draws what
  /// follows the jump as one labelled stretch rather than as repeats.
  static ({int perfIndex, String label})? navigationJump(
      List<Measure> measures) {
    final at = _unfold(measures).jumpAt;
    if (at == null) return null;
    final from = measures[at.from];
    final sign = from.daCapo ? 'D.C.' : 'D.S.';
    final suffix = measures.any((m) => m.fine)
        ? ' al Fine'
        : measures.any((m) => m.toCoda)
            ? ' al Coda'
            : '';
    return (perfIndex: at.perfIndex, label: '$sign$suffix');
  }

  /// [performanceOrder]'s walk, also reporting where its one jump happened:
  /// the document index of the D.C./D.S. bar and the order position after it.
  static ({List<int> order, ({int from, int perfIndex})? jumpAt}) _unfold(
      List<Measure> measures) {
    final order = <int>[];
    ({int from, int perfIndex})? jumpAt;
    final endRepeatTaken = <int>{};
    var returnIndex = 0;
    var jumped = false;
    var pass = 1; // which time through the current repeat (for endings)
    var arrivedByJump = false;
    var i = 0;
    var guard = 0;
    while (i < measures.length) {
      if (++guard > 1000000) break; // backstop against a malformed loop
      final m = measures[i];
      if (m.repeatStart) {
        returnIndex = i;
        if (!arrivedByJump) pass = 1;
      }
      arrivedByJump = false;
      // A measure under a volta for another pass is skipped. After a D.C. or
      // D.S. the player takes the last ending of each group.
      if (m.endings.isNotEmpty &&
          !m.endings.contains(jumped ? _lastEndingOfGroup(measures, i) : pass)) {
        i = _advance(measures, i, (r) => returnIndex = r, () => pass = 1);
        continue;
      }
      order.add(i);
      final next = i + 1 < measures.length ? measures[i + 1] : null;
      final implicitEnd = !jumped &&
          m.endings.isNotEmpty &&
          next != null &&
          next.endings.isNotEmpty &&
          !next.endings.contains(pass) &&
          next.endings.any((p) => p > pass);
      // A :| under an ending repeats on every pass a later ending is
      // waiting for (`[1,2 :| [3` repeats twice); others repeat once.
      final voltaRepeat = !jumped &&
          m.repeatEnd &&
          m.endings.isNotEmpty &&
          _lastEndingOfGroup(measures, i) > pass;
      if (voltaRepeat ||
          ((m.repeatEnd || implicitEnd) && !endRepeatTaken.contains(i))) {
        endRepeatTaken.add(i);
        i = returnIndex;
        pass++;
        arrivedByJump = true;
        continue;
      }
      if (jumped) {
        if (m.fine) break;
        if (m.toCoda) {
          final c = measures.indexWhere((x) => x.coda, i + 1);
          if (c > i) {
            i = c;
            continue;
          }
        }
      } else if (m.daCapo || m.dalSegno) {
        jumped = true;
        jumpAt = (from: i, perfIndex: order.length);
        var target = 0;
        if (!m.daCapo) {
          final s = measures.lastIndexWhere((x) => x.segno, i);
          if (s >= 0) target = s;
        }
        i = returnIndex = target;
        arrivedByJump = true;
        continue;
      }
      i = _advance(measures, i, (r) => returnIndex = r, () => pass = 1);
    }
    return (order: order, jumpAt: jumpAt);
  }

  /// Steps forward from document measure [i]. Leaving a volta group (a
  /// measure under an ending followed by one that isn't) ends that repeat:
  /// the pass count resets and a later bare `:|` returns to the bar after it.
  static int _advance(List<Measure> measures, int i,
      void Function(int) setReturn, void Function() resetPass) {
    final n = i + 1;
    if (measures[i].endings.isNotEmpty &&
        (n >= measures.length || measures[n].endings.isEmpty)) {
      resetPass();
      setReturn(n);
    }
    return n;
  }

  /// The highest pass named anywhere in the run of volta measures around [i].
  static int _lastEndingOfGroup(List<Measure> measures, int i) {
    var lo = i, hi = i;
    while (lo > 0 && measures[lo - 1].endings.isNotEmpty) {
      lo--;
    }
    while (hi + 1 < measures.length && measures[hi + 1].endings.isNotEmpty) {
      hi++;
    }
    var best = 1;
    for (var k = lo; k <= hi; k++) {
      for (final p in measures[k].endings) {
        if (p > best) best = p;
      }
    }
    return best;
  }

  /// Measure numbers whose visible notes don't total the expected beat count.
  ///
  /// Two kinds of short bar are notation, not error:
  ///  * a short FIRST measure — a pickup/anacrusis, even when OMR numbered it 1
  ///    instead of 0 (so the `number == 0` guard in
  ///    [Measure.isDurationMismatch] wouldn't catch it);
  ///  * a **pickup pair** — an incomplete bar completed by the pickup it runs
  ///    into. See [_pickupPairedIndices].
  Set<int> get flaggedMeasureNumbers {
    final paired = _pickupPairedIndices();
    final all = meters;
    final flagged = <int>{};
    for (var i = 0; i < measures.length; i++) {
      final m = measures[i];
      final meter = all[i];
      if (i == 0 && m.isShort(meter.beats, meter.beatType)) continue;
      if (paired.contains(i)) continue;
      if (m.isDurationMismatch(meter.beats, meter.beatType)) flagged.add(m.number);
    }
    return flagged;
  }

  /// Document indices of short measures that pair with an adjacent short
  /// measure to make exactly one full bar.
  ///
  /// This is the standard repeated-strain layout: `|: A2 | … | A6 :|` ends on a
  /// 3-beat bar that plays straight back into the 1-beat pickup, making four.
  /// Both bars are short on paper and neither is a mistake.
  ///
  /// Adjacency is *performance* order, so a `:|` is adjacent to the `|:` it
  /// jumps back to — and it's taken as a cycle, because the final incomplete bar
  /// of a tune is completed by the opening anacrusis, which is the whole reason
  /// the anacrusis is short in the first place.
  ///
  /// The boundary requirement is what stops this masking the OMR damage the flag
  /// exists to catch: a bar accidentally split into 3 + 1 mid-phrase also sums
  /// to a full bar, but has no repeat barline between the halves, so it stays
  /// flagged. A double barline ([Measure.doubleBarEnd]) counts as a boundary
  /// too: a song sheet splits a bar there between the verse's end and the
  /// chorus's pickup.
  Set<int> _pickupPairedIndices() {
    final order = performanceOrder(measures);
    if (order.length < 2) return const {};
    final all = meters;
    final paired = <int>{};
    for (var k = 0; k < order.length; k++) {
      final isWrap = k == order.length - 1;
      final ai = order[k];
      final bi = order[(k + 1) % order.length];
      if (ai == bi) continue;
      final a = measures[ai];
      final b = measures[bi];
      // A pickup pair completes the bar it starts: the meter of [a].
      final meter = all[ai];
      if (!a.isShort(meter.beats, meter.beatType)) continue;
      if (!b.isShort(meter.beats, meter.beatType)) continue;
      if (a.actualUnits + b.actualUnits != meter.units) continue;
      if (!a.repeatEnd && !a.doubleBarEnd && !b.repeatStart && !isWrap) {
        continue;
      }
      paired
        ..add(ai)
        ..add(bi);
    }
    return paired;
  }
}

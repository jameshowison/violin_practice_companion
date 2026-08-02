import 'duration_step.dart';
import 'note_event.dart';

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

  const Measure({
    required this.number,
    required this.notes,
    this.hiddenLeadNotes = const [],
    this.repeatStart = false,
    this.repeatEnd = false,
  });

  /// Returns a copy with replaced [notes], carrying the measure number, hidden
  /// pickup rests, and repeat flags through unless explicitly overridden. The
  /// jianpu/fingering processors rebuild measures via this method, so the repeat
  /// flags must survive to `parsedPieceProvider`'s output.
  Measure copyWithNotes(List<NoteEvent> notes,
          {bool? repeatStart, bool? repeatEnd}) =>
      Measure(
        number: number,
        notes: notes,
        hiddenLeadNotes: hiddenLeadNotes,
        repeatStart: repeatStart ?? this.repeatStart,
        repeatEnd: repeatEnd ?? this.repeatEnd,
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
  int get actualUnits => notes.fold<int>(
      0,
      (sum, n) =>
          n.isChord ? sum : sum + thirtySecondUnits(n.noteValue, n.dotted));

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
  final int beatsPerMeasure;
  final int beatType;

  const ParsedPiece({
    required this.keySignature,
    required this.keyFifths,
    required this.keyMode,
    required this.measures,
    this.divisions = 1,
    this.beatsPerMeasure = 4,
    this.beatType = 4,
  });

  /// The same music read under a different meter.
  ///
  /// Nothing about the notes changes — this is the "what if it were 2/2?"
  /// question the time-signature editor asks so it can show how many bars would
  /// still fail to add up before anything is written to the file.
  ParsedPiece copyWithTime({int? beatsPerMeasure, int? beatType}) =>
      ParsedPiece(
        keySignature: keySignature,
        keyFifths: keyFifths,
        keyMode: keyMode,
        measures: measures,
        divisions: divisions,
        beatsPerMeasure: beatsPerMeasure ?? this.beatsPerMeasure,
        beatType: beatType ?? this.beatType,
      );

  ParsedPiece copyWithMeasures(List<Measure> measures) => ParsedPiece(
        keySignature: keySignature,
        keyFifths: keyFifths,
        keyMode: keyMode,
        measures: measures,
        divisions: divisions,
        beatsPerMeasure: beatsPerMeasure,
        beatType: beatType,
      );

  List<NoteEvent> get allNotes =>
      measures.expand((m) => m.notes).toList(growable: false);

  /// Document-measure indices in performance order, honoring simple forward/
  /// backward repeats. A forward repeat ([Measure.repeatStart]) sets the return
  /// point; a backward repeat ([Measure.repeatEnd]), the first time it's
  /// reached, jumps back to that return point once (defaulting to the piece
  /// start if no forward repeat preceded it), then continues past on the second
  /// arrival. Nested repeats and voltas/endings are out of scope. With no
  /// repeats the result is the identity `[0, 1, … n-1]`.
  ///
  /// Shared by MIDI generation (audio order) and the section-organized layout /
  /// staff unfold (so a `|: A :|` span shows up as two `A`s on the staff).
  static List<int> performanceOrder(List<Measure> measures) {
    final order = <int>[];
    final endRepeatTaken = <int>{};
    var returnIndex = 0;
    var i = 0;
    var guard = 0;
    while (i < measures.length) {
      if (++guard > 1000000) break; // backstop against a malformed loop
      final m = measures[i];
      if (m.repeatStart) returnIndex = i;
      order.add(i);
      if (m.repeatEnd && !endRepeatTaken.contains(i)) {
        endRepeatTaken.add(i);
        i = returnIndex;
        continue;
      }
      i++;
    }
    return order;
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
    final flagged = <int>{};
    for (var i = 0; i < measures.length; i++) {
      final m = measures[i];
      if (i == 0 && m.isShort(beatsPerMeasure, beatType)) continue;
      if (paired.contains(i)) continue;
      if (m.isDurationMismatch(beatsPerMeasure, beatType)) flagged.add(m.number);
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
  /// flagged.
  Set<int> _pickupPairedIndices() {
    final order = performanceOrder(measures);
    if (order.length < 2) return const {};
    final expected = beatsPerMeasure * 32 ~/ beatType;
    final paired = <int>{};
    for (var k = 0; k < order.length; k++) {
      final isWrap = k == order.length - 1;
      final ai = order[k];
      final bi = order[(k + 1) % order.length];
      if (ai == bi) continue;
      final a = measures[ai];
      final b = measures[bi];
      if (!a.isShort(beatsPerMeasure, beatType)) continue;
      if (!b.isShort(beatsPerMeasure, beatType)) continue;
      if (a.actualUnits + b.actualUnits != expected) continue;
      if (!a.repeatEnd && !b.repeatStart && !isWrap) continue;
      paired
        ..add(ai)
        ..add(bi);
    }
    return paired;
  }
}

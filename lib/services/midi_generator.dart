import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/note_event.dart';
import '../models/parsed_piece.dart';

class ScheduledNote {
  final double onsetSeconds;
  final double offsetSeconds;
  final int midiNote;

  const ScheduledNote(this.onsetSeconds, this.offsetSeconds, this.midiNote);
}

class HighlightEvent {
  final int measureNumber;   // 1-indexed
  final int noteIndex;       // 0-indexed within Measure.notes (includes rests)
  final bool isLong;         // whole, half, or dotted-quarter — false for rests
  final double onsetSeconds; // absolute from piece start (BPM-dependent)
  final double offsetSeconds;
  final double beatPosition; // absolute beats from piece start (BPM-independent, for OSMD)
  // Position in the expanded performance order (which unfolded measure-slot this
  // note plays in). On a repeat, the SAME measure plays at a LATER performance
  // index, so the minimap can light the exact pass (1st vs 2nd A). Folded
  // notation keys off measureNumber; the unfolded minimap keys off this.
  final int performanceIndex;
  // This note continues a tie: it is held, not struck — its sound belongs to
  // an earlier [ScheduledNote]. Kept as an event all the same (it has its own
  // notehead, and a bar that opens with one would otherwise have no event to
  // light the bar by); a consumer that wants only struck notes can skip it.
  final bool isTieContinuation;

  const HighlightEvent({
    required this.measureNumber,
    required this.noteIndex,
    required this.isLong,
    required this.onsetSeconds,
    required this.offsetSeconds,
    required this.beatPosition,
    this.performanceIndex = 0,
    this.isTieContinuation = false,
  });
}

class MidiData {
  final List<ScheduledNote> notes; // sorted by onset ascending
  final List<double> measureOnsetSeconds; // index i → onset of measures[i]
  // measureNumbers[i] is the Measure.number whose onset is measureOnsetSeconds[i],
  // in document order. NOT i+1: a pickup makes measures[0].number == 0, so callers
  // must map a measure number → index via this list rather than assuming number-1.
  final List<int> measureNumbers;
  final double totalDurationSeconds;
  // Per measure (0-indexed), per note (0-indexed): absolute (onsetSecs, offsetSecs)
  final List<List<(double, double)>> measureNoteTimings;
  final List<HighlightEvent> highlightEvents; // sorted by onset, one entry per note/rest

  const MidiData({
    required this.notes,
    required this.measureOnsetSeconds,
    required this.measureNumbers,
    required this.totalDurationSeconds,
    required this.measureNoteTimings,
    required this.highlightEvents,
  });

  /// Array index of the FIRST occurrence of [measureNumber], or -1 if absent.
  /// With repeats a measure can appear more than once in performance order.
  int indexOfMeasure(int measureNumber) => measureNumbers.indexOf(measureNumber);

  /// Array index of the LAST occurrence of [measureNumber], or -1 if absent.
  /// Used as a range end-bound so a selection spanning a repeated measure plays
  /// through every occurrence rather than stopping at the first.
  int lastIndexOfMeasure(int measureNumber) =>
      measureNumbers.lastIndexOf(measureNumber);
}

class MidiGenerator {
  int _tpb;
  bool _initialized;

  /// Production constructor — reads tpb from midi_patch.json on first [init].
  MidiGenerator()
      : _tpb = 480,
        _initialized = false;

  /// Test constructor — skips asset loading and uses [ticksPerBeat] directly.
  MidiGenerator.forTest({int ticksPerBeat = 480})
      : _tpb = ticksPerBeat,
        _initialized = true;

  Future<void> init() async {
    if (_initialized) return;
    final j = jsonDecode(
          await rootBundle.loadString('assets/lookup_tables/midi_patch.json'),
        ) as Map<String, dynamic>;
    _tpb = j['ticksPerQuarterNote'] as int;
    _initialized = true;
  }

  /// Converts [piece] at [bpm] to scheduled note events with absolute times.
  ///
  /// Repeats are honored: the measures are played in an *expanded performance
  /// order* (a `|: A B :|` span yields A B A B). Onset/offset times advance off
  /// a monotonic performance cursor (so audio + the playback time→event pointer
  /// stay correct), while each highlight's [HighlightEvent.beatPosition] is
  /// anchored to the measure's position in the ORIGINAL score — so on a replay
  /// the beat value drops back, and the OSMD cursor's backward-seek reset jumps
  /// it to the repeat start (no bridge change needed). With no repeats the
  /// expanded order is identity and every value matches the un-repeated output.
  ///
  /// Ties are honoured in performance order: a [NoteEvent.tieStop] note whose
  /// pitch matches a [NoteEvent.tieStart] note ending exactly where it begins
  /// is folded into that note's [ScheduledNote] — one note-on, held through the
  /// chain, across barlines and around repeats alike. A tie whose partner isn't
  /// there (the repeat sent playback elsewhere, an edit changed one end's
  /// pitch, a rest in between) is just struck again. Time itself is untouched:
  /// every note still advances the cursor, so measure onsets, the total length
  /// and every highlight are exactly what they were without ties — which is
  /// what keeps a saved audio alignment, keyed to measure onsets, valid.
  MidiData generate(ParsedPiece piece, int bpm) {
    assert(_initialized, 'Call init() before generate()');
    final secsPerTick = 60.0 / (bpm * _tpb);
    final notes = <ScheduledNote>[];
    final measureOnsets = <double>[];
    final measureNumbers = <int>[];
    final measureNoteTimings = <List<(double, double)>>[];
    final highlightEvents = <HighlightEvent>[];
    double cursor = 0.0;
    // The cursor in ticks, in performance order, so "ends where it begins" is
    // an exact comparison rather than a float one.
    int perfTick = 0;
    // Open ties by MIDI number: the [notes] entry still sounding, and the tick
    // its written note ends at. Pitch-keyed, so each voice of a double-stop
    // ties on its own.
    final openTies = <int, ({int noteIndex, int endTick})>{};

    // Pre-pass: cumulative score ticks at each measure's document start
    // (including hidden lead/pickup notes), used to anchor beatPosition.
    final scoreStartTicks = <int>[];
    int acc = 0;
    for (final measure in piece.measures) {
      scoreStartTicks.add(acc);
      for (final hidden in measure.hiddenLeadNotes) {
        acc += _ticks(hidden);
      }
      for (final note in measure.notes) {
        // Chord members share the primary note's onset and add no time.
        if (!note.isChord) acc += _ticks(note);
      }
    }

    final order = ParsedPiece.performanceOrder(piece.measures);
    for (var oi = 0; oi < order.length; oi++) {
      final idx = order[oi];
      final measure = piece.measures[idx];
      measureOnsets.add(cursor);
      measureNumbers.add(measure.number);
      int scoreTick = scoreStartTicks[idx];
      for (final hidden in measure.hiddenLeadNotes) {
        final t = _ticks(hidden);
        cursor += t * secsPerTick;
        scoreTick += t;
        perfTick += t;
      }
      final noteTimings = <(double, double)>[];
      // A chord member reuses the primary note's onset/duration/beat and does
      // not advance the cursor, so the whole chord sounds together in one slot.
      double chordOnset = cursor;
      double chordDur = 0.0;
      int chordScoreTick = scoreTick;
      int chordPerfTick = perfTick;
      for (int ni = 0; ni < measure.notes.length; ni++) {
        final note = measure.notes[ni];
        final isChordMember = note.isChord && ni > 0;
        final double onset;
        final double dur;
        if (isChordMember) {
          onset = chordOnset;
          dur = chordDur;
        } else {
          onset = cursor;
          dur = _ticks(note) * secsPerTick;
          chordOnset = onset;
          chordDur = dur;
          chordScoreTick = scoreTick;
          chordPerfTick = perfTick;
        }
        final offset = onset + dur;
        noteTimings.add((onset, offset));

        var continuesTie = false;
        if (!note.isRest) {
          final midi = note.midiNumber;
          final open = openTies[midi];
          if (note.tieStop && open != null && open.endTick == chordPerfTick) {
            final held = notes[open.noteIndex];
            notes[open.noteIndex] = ScheduledNote(held.onsetSeconds, offset, midi);
            continuesTie = true;
          } else {
            notes.add(ScheduledNote(onset, offset, midi));
          }
          if (note.tieStart) {
            openTies[midi] = (
              noteIndex: continuesTie ? open!.noteIndex : notes.length - 1,
              endTick: chordPerfTick + _ticks(note),
            );
          } else {
            openTies.remove(midi);
          }
        }

        highlightEvents.add(HighlightEvent(
          measureNumber: measure.number,
          noteIndex: ni,
          isLong: !note.isRest && _isLongerThanQuarter(note),
          onsetSeconds: onset,
          offsetSeconds: offset,
          beatPosition: chordScoreTick / (_tpb * 4),
          performanceIndex: oi,
          isTieContinuation: continuesTie,
        ));
        if (!isChordMember) {
          cursor += dur;
          scoreTick += _ticks(note);
          perfTick += _ticks(note);
        }
      }
      measureNoteTimings.add(noteTimings);
    }

    return MidiData(
      notes: notes,
      measureOnsetSeconds: measureOnsets,
      measureNumbers: measureNumbers,
      totalDurationSeconds: cursor,
      measureNoteTimings: measureNoteTimings,
      highlightEvents: highlightEvents,
    );
  }

  int _ticks(NoteEvent note) {
    final base = switch (note.noteValue) {
      NoteValue.whole => _tpb * 4,
      NoteValue.half => _tpb * 2,
      NoteValue.quarter => _tpb,
      NoteValue.eighth => _tpb ~/ 2,
      NoteValue.sixteenth => _tpb ~/ 4,
    };
    return note.dotted ? (base * 3) ~/ 2 : base;
  }

  static bool _isLongerThanQuarter(NoteEvent note) {
    if (note.noteValue == NoteValue.whole || note.noteValue == NoteValue.half) return true;
    if (note.noteValue == NoteValue.quarter && note.dotted) return true;
    return false;
  }
}

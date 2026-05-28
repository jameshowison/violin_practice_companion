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

class MidiData {
  final List<ScheduledNote> notes; // sorted by onset ascending
  final List<double> measureOnsetSeconds; // index i → onset of measure i+1
  final double totalDurationSeconds;

  const MidiData({
    required this.notes,
    required this.measureOnsetSeconds,
    required this.totalDurationSeconds,
  });
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
  MidiData generate(ParsedPiece piece, int bpm) {
    assert(_initialized, 'Call init() before generate()');
    final secsPerTick = 60.0 / (bpm * _tpb);
    final notes = <ScheduledNote>[];
    final measureOnsets = <double>[];
    double cursor = 0.0;

    for (final measure in piece.measures) {
      measureOnsets.add(cursor);
      for (final note in measure.notes) {
        final ticks = _ticks(note);
        final dur = ticks * secsPerTick;
        if (!note.isRest) {
          notes.add(ScheduledNote(cursor, cursor + dur, note.midiNumber));
        }
        cursor += dur;
      }
    }

    return MidiData(
      notes: notes,
      measureOnsetSeconds: measureOnsets,
      totalDurationSeconds: cursor,
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
}

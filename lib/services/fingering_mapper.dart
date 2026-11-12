import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/gdae_tuning.dart';
import '../models/note_event.dart';
import '../models/note_number_mode.dart';
import '../models/parsed_piece.dart';

class FingeringMapper {
  Map<String, dynamic>? _fingeringTable;

  Future<void> init() async {
    final rawFingering = await rootBundle
        .loadString('assets/engine/lookup_tables/fingering_first_position.json');
    _fingeringTable = json.decode(rawFingering) as Map<String, dynamic>;
  }

  /// Whether [midi] is both an open string and a 4th finger on the string
  /// below — D4, A4, E5 in first position. These are the only notes where
  /// the fingering is a choice, and so the only ones that take an override.
  static bool hasFourthFingerChoice(int midi) =>
      midi != GdaeTuning.openMidi['G'] &&
      GdaeTuning.openMidi.containsValue(midi);

  /// Fingers each note from the first-position table. On the notes with a
  /// choice ([hasFourthFingerChoice]), the first of these that applies wins:
  ///
  /// 1. The note's own `<fingering>` of 0 or 4 ([NoteEvent.scoreFinger]) —
  ///    printed in the score, or set in the measure editor, which writes it
  ///    back the same way. Any other number there is ignored.
  /// 2. Under [ViolinStringPreference.auto], the 4th finger when the note is
  ///    a neighbour note on the string below ([_fourthByContext]).
  /// 3. A tied continuation without its own follows the note it holds.
  /// 4. [preference]: open strings (also Auto's fallback) or 4th finger.
  ///
  /// [preference] is the piece's setting (`violinStringPreferenceProvider`).
  ParsedPiece map(ParsedPiece piece,
      {ViolinStringPreference preference = ViolinStringPreference.auto}) {
    assert(_fingeringTable != null, 'Call init() before map()');
    final notes = _fingeringTable!['notes'] as Map<String, dynamic>;
    final byContext = preference == ViolinStringPreference.auto
        ? _fourthByContext(piece)
        : const <NoteEvent>{};

    // The last single note's pitch and choice, so a tied continuation can
    // follow the note it holds over (across a barline too).
    int? heldMidi;
    bool? heldFourth;

    final newMeasures = [
      for (final measure in piece.measures)
        measure.copyWithNotes([
          for (final note in measure.notes)
            () {
              if (note.isRest) return note;
              final entry =
                  notes[note.midiNumber.toString()] as Map<String, dynamic>?;
              if (entry == null) return note;

              var chosenString = entry['string'] as String;
              var chosenFinger = entry['finger'] as String;
              final alt = entry['alt'] as Map<String, dynamic>?;

              if (alt != null) {
                final wantFourth = switch (note.scoreFinger) {
                  4 => true,
                  0 => false,
                  _ when note.tieStop &&
                          heldMidi == note.midiNumber &&
                          heldFourth != null =>
                    heldFourth!,
                  _ => switch (preference) {
                      ViolinStringPreference.fourthFinger => true,
                      ViolinStringPreference.openStrings => false,
                      ViolinStringPreference.auto => byContext.contains(note),
                    },
                };
                // The table lists one of the pair as primary, the other as alt.
                if ((chosenFinger == '0') == wantFourth) {
                  chosenString = alt['string'] as String;
                  chosenFinger = alt['finger'] as String;
                }
                if (!note.isChord) heldFourth = wantFourth;
              } else if (!note.isChord) {
                heldFourth = null;
              }
              if (!note.isChord) heldMidi = note.midiNumber;

              return note.copyWith(
                fingerString: chosenString,
                fingerNumber: chosenFinger,
              );
            }(),
        ]),
    ];

    return piece.copyWithMeasures(newMeasures);
  }

  /// The choice notes that Auto plays with the 4th finger: those whose
  /// melodic neighbours on BOTH sides are a half or whole step below — i.e.
  /// on the 4th finger's own string, as its 3rd finger. `D5 E5 D5`,
  /// `G4 A4 G4`, `D♯5 E5 D♯5`: the open string there means crossing over and
  /// straight back, which is what the 4th finger is taught for.
  ///
  /// Deliberately narrow. A wider rule ("fewest string crossings") fingered
  /// ordinary beginner tunes — Lightly Row's C♯–E — with a 4th that no method
  /// book uses; this one changed about 1 in 30 choice notes across the dev
  /// library, every one a textbook 4th-finger spot.
  ///
  /// A repeated note (or a tie) counts once, so `D5 E5 E5 E5 D5` qualifies
  /// and the whole run is fingered alike. The melody runs across barlines; a
  /// rest, a chord, or the start or end of the piece breaks it, and a note
  /// next to one is left to the fallback.
  static Set<NoteEvent> _fourthByContext(ParsedPiece piece) {
    // Melodic runs: consecutive single notes of one pitch; null = a break.
    final runs = <List<NoteEvent>?>[];
    final all = piece.measures.expand((m) => m.notes).toList();
    for (var i = 0; i < all.length; i++) {
      final n = all[i];
      if (n.isChord) continue; // the stack's primary already broke the run
      final stacked = i + 1 < all.length && all[i + 1].isChord;
      if (n.isRest || stacked) {
        if (runs.isEmpty || runs.last != null) runs.add(null);
        continue;
      }
      final last = runs.isEmpty ? null : runs.last;
      if (last != null && last.first.midiNumber == n.midiNumber) {
        last.add(n);
      } else {
        runs.add([n]);
      }
    }

    bool stepBelow(List<NoteEvent>? neighbour, int midi) {
      if (neighbour == null) return false;
      final d = midi - neighbour.first.midiNumber;
      return d == 1 || d == 2;
    }

    final fourth = Set<NoteEvent>.identity();
    for (var k = 1; k + 1 < runs.length; k++) {
      final run = runs[k];
      if (run == null || !hasFourthFingerChoice(run.first.midiNumber)) continue;
      final midi = run.first.midiNumber;
      if (stepBelow(runs[k - 1], midi) && stepBelow(runs[k + 1], midi)) {
        fourth.addAll(run);
      }
    }
    return fourth;
  }
}

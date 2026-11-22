import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/instrument_profile.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import '../models/note_annotation.dart';
import '../models/note_number_mode.dart';

class FingeringMapper {
  Map<String, dynamic>? _fingeringTable;

  Future<void> init() async {
    final rawFingering = await rootBundle
        .loadString('assets/engine/lookup_tables/fingering_first_position.json');
    _fingeringTable = json.decode(rawFingering) as Map<String, dynamic>;
  }

  /// Whether [midi] is both an open string and a 4th finger on the string
  /// below, on [profile] (violin: D4, A4, E5 in first position). These are
  /// the only notes where the fingering is a choice, and so the only ones
  /// that take an override.
  static bool hasFourthFingerChoice(int midi,
          [InstrumentProfile profile = InstrumentProfile.violin]) =>
      profile.hasFourthFingerChoice(midi);

  /// Fingers each note from the first-position table. On the notes with a
  /// choice ([hasFourthFingerChoice]), the first of these that applies wins:
  ///
  /// 1. The violin layer's choice for the note ([choices], keyed
  ///    `<measure>:<index>`; see `InstrumentLayerStore`), else the note's own
  ///    `<fingering>` of 0 or 4 ([NoteEvent.scoreFinger]): a score shared
  ///    before choices left the score, or the measure editor's unsaved bar.
  ///    Any other number there is ignored.
  /// 2. Under [ViolinStringPreference.auto], the 4th finger when the note is
  ///    a neighbour note on the string below ([_fourthByContext]).
  /// 3. A tied continuation without its own follows the note it holds.
  /// 4. [preference]: open strings (also Auto's fallback) or 4th finger.
  ///
  /// [preference] is the piece's setting (`violinStringPreferenceProvider`).
  ///
  /// [profile] is the instrument. The table is the violin's; another
  /// four-string instrument tuned in fifths (the viola) reads it a string
  /// lower: its note is looked up where the violin plays the same finger on
  /// the matching string, and the string renamed (violin G D A E to viola
  /// C G D A). The finger labels, L/H included, carry over verbatim.
  ///
  /// An instrument without strings (the recorder) gets no string fingering:
  /// [piece] is returned as it is, with no `fingerString`/`fingerNumber`, so
  /// no view draws a string label. A wind's chart fingering is step W2.
  ParsedPiece map(ParsedPiece piece,
      {ViolinStringPreference preference = ViolinStringPreference.auto,
      Map<String, int> choices = const {},
      InstrumentProfile profile = InstrumentProfile.violin}) {
    assert(_fingeringTable != null, 'Call init() before map()');
    if (!profile.hasStrings) return piece;
    final notes = _fingeringTable!['notes'] as Map<String, dynamic>;
    const violin = InstrumentProfile.violin;
    final offset = violin.openMidi.first - profile.openMidi.first;
    String rename(String s) {
      final i = violin.strings.indexOf(s);
      return i < 0 || i >= profile.strings.length ? s : profile.strings[i];
    }
    final byContext = preference == ViolinStringPreference.auto
        ? _fourthByContext(piece, profile)
        : const <NoteEvent>{};

    // The last single note's pitch and choice, so a tied continuation can
    // follow the note it holds over (across a barline too).
    int? heldMidi;
    bool? heldFourth;

    final newMeasures = [
      for (final measure in piece.measures)
        measure.copyWithNotes([
          for (var i = 0; i < measure.notes.length; i++)
            () {
              final note = measure.notes[i];
              if (note.isRest) return note;
              final entry = notes[(note.midiNumber + offset).toString()]
                  as Map<String, dynamic>?;
              if (entry == null) return note;

              var chosenString = rename(entry['string'] as String);
              var chosenFinger = entry['finger'] as String;
              final rawAlt = entry['alt'] as Map<String, dynamic>?;
              final alt = rawAlt == null
                  ? null
                  : {...rawAlt, 'string': rename(rawAlt['string'] as String)};

              if (alt != null) {
                final pinned =
                    choices['${measure.number}:$i'] ?? note.scoreFinger;
                final wantFourth = switch (pinned) {
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

              return note.withFingering(
                string: chosenString,
                number: chosenFinger,
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
  static Set<NoteEvent> _fourthByContext(
      ParsedPiece piece, InstrumentProfile profile) {
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
      if (run == null ||
          !profile.hasFourthFingerChoice(run.first.midiNumber)) {
        continue;
      }
      final midi = run.first.midiNumber;
      if (stepBelow(runs[k - 1], midi) && stepBelow(runs[k + 1], midi)) {
        fourth.addAll(run);
      }
    }
    return fourth;
  }
}

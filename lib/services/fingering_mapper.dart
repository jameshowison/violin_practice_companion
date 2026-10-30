import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/note_number_mode.dart';
import '../models/parsed_piece.dart';

class FingeringMapper {
  Map<String, dynamic>? _fingeringTable;

  Future<void> init() async {
    final rawFingering = await rootBundle
        .loadString('assets/lookup_tables/fingering_first_position.json');
    _fingeringTable = json.decode(rawFingering) as Map<String, dynamic>;
  }

  /// [preference] chooses between an open string and the 4th finger below it
  /// wherever the table offers both — see [ViolinStringPreference]. It is the
  /// piece's setting (`violinStringPreferenceProvider`); this used to come from
  /// `open_string_preferences.json`, which no setting could override.
  ParsedPiece map(ParsedPiece piece,
      {ViolinStringPreference preference =
          ViolinStringPreference.openStrings}) {
    final preferOpen = preference == ViolinStringPreference.openStrings;
    assert(_fingeringTable != null, 'Call init() before map()');
    final notes = _fingeringTable!['notes'] as Map<String, dynamic>;

    final newMeasures = piece.measures.map((measure) {
      final newNotes = measure.notes.map((note) {
        if (note.isRest) return note;
        final entry = notes[note.midiNumber.toString()] as Map<String, dynamic>?;
        if (entry == null) return note;

        final primaryString = entry['string'] as String;
        final primaryFinger = entry['finger'] as String;
        final alt = entry['alt'] as Map<String, dynamic>?;

        String chosenString = primaryString;
        String chosenFinger = primaryFinger;

        if (alt != null) {
          final altFinger = alt['finger'] as String;
          final altString = alt['string'] as String;
          if (preferOpen && altFinger == '0') {
            chosenString = altString;
            chosenFinger = altFinger;
          } else if (!preferOpen && primaryFinger == '0') {
            chosenString = altString;
            chosenFinger = altFinger;
          }
        }

        return note.copyWith(
          fingerString: chosenString,
          fingerNumber: chosenFinger,
        );
      }).toList();
      return measure.copyWithNotes(newNotes);
    }).toList();

    return piece.copyWithMeasures(newMeasures);
  }
}

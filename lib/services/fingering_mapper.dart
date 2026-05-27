import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/parsed_piece.dart';

class FingeringMapper {
  Map<String, dynamic>? _fingeringTable;
  String _preference = 'fingered';

  Future<void> init() async {
    final rawFingering = await rootBundle
        .loadString('assets/lookup_tables/fingering_first_position.json');
    _fingeringTable = json.decode(rawFingering) as Map<String, dynamic>;

    final rawPref = await rootBundle
        .loadString('assets/lookup_tables/open_string_preferences.json');
    final prefMap = json.decode(rawPref) as Map<String, dynamic>;
    _preference = prefMap['default'] as String? ?? 'fingered';
  }

  void updatePreference(String preference) {
    _preference = preference;
  }

  String get preference => _preference;

  ParsedPiece map(ParsedPiece piece) {
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
          if (_preference == 'open' && altFinger == '0') {
            chosenString = altString;
            chosenFinger = altFinger;
          } else if (_preference == 'fingered' && primaryFinger == '0') {
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

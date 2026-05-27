import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/parsed_piece.dart';

class JianpuConverter {
  Map<String, dynamic>? _keyMap;

  Future<void> init() async {
    final raw = await rootBundle.loadString('assets/lookup_tables/jianpu_key_map.json');
    _keyMap = json.decode(raw) as Map<String, dynamic>;
  }

  ParsedPiece convert(ParsedPiece piece) {
    assert(_keyMap != null, 'Call init() before convert()');
    final keys = _keyMap!['keys'] as Map<String, dynamic>;
    final keyEntry = keys[piece.keyFifths.toString()] as Map<String, dynamic>?;

    if (keyEntry == null) return piece;

    final scale = (keyEntry['scale'] as List).cast<int>();
    final tonicPc = keyEntry['tonicPc'] as int;

    // Reference octave: octave containing the tonic pitch class
    // For violin, the natural reference is octave 4 for most keys
    final referenceOctave = _referenceOctave(tonicPc);

    final newMeasures = piece.measures.map((measure) {
      final newNotes = measure.notes.map((note) {
        if (note.isRest) {
          return note.copyWith(jianpuNumber: 0, jianpuOctaveDots: 0);
        }
        final pc = note.midiNumber % 12;
        final noteOctave = (note.midiNumber ~/ 12) - 1;

        int jianpuNum;
        bool? sharp;
        final scaleIdx = scale.indexOf(pc);
        if (scaleIdx >= 0) {
          jianpuNum = scaleIdx + 1;
          sharp = null;
        } else {
          // Accidental: find the nearest lower scale degree
          int nearest = 0;
          for (int i = scale.length - 1; i >= 0; i--) {
            if (scale[i] < pc || (scale[i] > pc && scale[i] - pc > 6)) {
              nearest = i;
              break;
            }
          }
          jianpuNum = nearest + 1;
          sharp = true;
        }

        final octaveDots = noteOctave - referenceOctave;

        return note.copyWith(
          jianpuNumber: jianpuNum,
          jianpuOctaveDots: octaveDots,
          jianpuAccidentalSharp: sharp,
        );
      }).toList();
      return measure.copyWithNotes(newNotes);
    }).toList();

    return piece.copyWithMeasures(newMeasures);
  }

  int _referenceOctave(int tonicPc) {
    // Middle C = MIDI 60, octave 4. G (pc=7) in octave 4 starts at MIDI 67.
    // Reference octave is octave 4 for most violin keys.
    return 4;
  }
}

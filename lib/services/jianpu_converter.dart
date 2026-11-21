import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/note_annotation.dart';
import '../models/parsed_piece.dart';
import 'jianpu_digits.dart';

/// Fills in each note's Jianpu ([NoteAnnotation]) from [JianpuDigits], with
/// the key table loaded from the app's assets.
class JianpuConverter {
  JianpuDigits? _digits;

  Future<void> init() async {
    final raw = await rootBundle.loadString('assets/engine/lookup_tables/jianpu_key_map.json');
    _digits = JianpuDigits(json.decode(raw) as Map<String, dynamic>);
  }

  ParsedPiece convert(ParsedPiece piece) {
    assert(_digits != null, 'Call init() before convert()');
    final digits = _digits!;
    if (!digits.covers(piece.keyFifths)) return piece;

    final newMeasures = piece.measures.map((measure) {
      final newNotes = measure.notes.map((note) {
        final d = digits.digitOf(note, piece.keyFifths)!;
        return note.withJianpu(
          number: d.number,
          octaveDots: d.octaveDots,
          accidentalSharp: d.sharp,
        );
      }).toList();
      return measure.copyWithNotes(newNotes);
    }).toList();

    return piece.copyWithMeasures(newMeasures);
  }
}

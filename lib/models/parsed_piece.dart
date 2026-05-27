import 'note_event.dart';

class Measure {
  final int number;
  final List<NoteEvent> notes;

  const Measure({required this.number, required this.notes});

  Measure copyWithNotes(List<NoteEvent> notes) =>
      Measure(number: number, notes: notes);
}

class ParsedPiece {
  final String keySignature;
  final int keyFifths;
  final KeyMode keyMode;
  final List<Measure> measures;

  const ParsedPiece({
    required this.keySignature,
    required this.keyFifths,
    required this.keyMode,
    required this.measures,
  });

  ParsedPiece copyWithMeasures(List<Measure> measures) => ParsedPiece(
        keySignature: keySignature,
        keyFifths: keyFifths,
        keyMode: keyMode,
        measures: measures,
      );

  List<NoteEvent> get allNotes =>
      measures.expand((m) => m.notes).toList(growable: false);
}

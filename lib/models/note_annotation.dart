import 'package:musicxml_tools/musicxml_tools.dart';

/// The app's [NoteEvent.annotation]: what a note's fingering is on the
/// instrument, and what it is in Jianpu. [NoteEvent] itself is purely
/// musical, so that it can live in a library; these are filled in by
/// `FingeringMapper` and `JianpuConverter` and read through [NoteAnnotations].
class NoteAnnotation {
  /// The string the note is played on (`'A'`), from `FingeringMapper`.
  final String? fingerString;

  /// The fingering label, verbatim from the lookup table (`'A2L'`): the L/H
  /// suffix is data and is never stripped (CLAUDE.md).
  final String? fingerNumber;

  final int? jianpuNumber;
  final int? jianpuOctaveDots;
  final bool? jianpuAccidentalSharp;

  const NoteAnnotation({
    this.fingerString,
    this.fingerNumber,
    this.jianpuNumber,
    this.jianpuOctaveDots,
    this.jianpuAccidentalSharp,
  });
}

/// The annotation's fields as if they were the note's own, as they were
/// before [NoteEvent] became purely musical.
extension NoteAnnotations on NoteEvent {
  NoteAnnotation? get _a {
    final a = annotation;
    return a is NoteAnnotation ? a : null;
  }

  String? get fingerString => _a?.fingerString;
  String? get fingerNumber => _a?.fingerNumber;
  int? get jianpuNumber => _a?.jianpuNumber;
  int? get jianpuOctaveDots => _a?.jianpuOctaveDots;
  bool? get jianpuAccidentalSharp => _a?.jianpuAccidentalSharp;

  /// This note with its fingering set; a null keeps what was there, as
  /// `copyWith` always has.
  NoteEvent withFingering({String? string, String? number}) =>
      copyWith(annotation: NoteAnnotation(
        fingerString: string ?? fingerString,
        fingerNumber: number ?? fingerNumber,
        jianpuNumber: jianpuNumber,
        jianpuOctaveDots: jianpuOctaveDots,
        jianpuAccidentalSharp: jianpuAccidentalSharp,
      ));

  /// This note with its Jianpu set; a null keeps what was there.
  NoteEvent withJianpu({int? number, int? octaveDots, bool? accidentalSharp}) =>
      copyWith(annotation: NoteAnnotation(
        fingerString: fingerString,
        fingerNumber: fingerNumber,
        jianpuNumber: number ?? jianpuNumber,
        jianpuOctaveDots: octaveDots ?? jianpuOctaveDots,
        jianpuAccidentalSharp: accidentalSharp ?? jianpuAccidentalSharp,
      ));
}

/// Each note's fingering label in document order (rests included, as null),
/// for `FingeringXmlInjector.injectPlaceholders`. A note has a label only
/// when it has both a string and a finger.
List<String?> fingeringLabelsOf(ParsedPiece piece) => [
      for (final m in piece.measures)
        for (final n in m.notes)
          n.isRest || n.fingerString == null ? null : n.fingerNumber,
    ];

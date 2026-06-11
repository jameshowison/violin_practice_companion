enum NoteValue { whole, half, quarter, eighth, sixteenth }

enum KeyMode { major, minor }

enum DisplayMode { staff, staffFingering, jianpu, fingering, combined }

class NoteEvent {
  final String pitch;
  final int midiNumber;
  final int octave;
  final NoteValue noteValue;
  final bool dotted;
  final bool isRest;
  final int? scoreFinger;

  /// The visible accidental sign, as the raw MusicXML `<accidental>` value
  /// (`'natural'`, `'sharp'`, `'flat'`, …) — `null` means no sign is drawn and
  /// the note follows the key signature. This is the *displayed* accidental,
  /// distinct from the sounding alteration encoded in [pitch]: e.g. a courtesy
  /// natural on a C in G major has `displayAccidental: 'natural'` while [pitch]
  /// is still `'C5'` (alter 0). Without it, the editor can't show or remove a
  /// redundant accidental.
  final String? displayAccidental;

  // Populated by JianpuConverter
  final int? jianpuNumber;
  final int? jianpuOctaveDots;
  final bool? jianpuAccidentalSharp;

  // Populated by FingeringMapper
  final String? fingerString;
  final String? fingerNumber;

  const NoteEvent({
    required this.pitch,
    required this.midiNumber,
    required this.octave,
    required this.noteValue,
    required this.dotted,
    required this.isRest,
    this.scoreFinger,
    this.displayAccidental,
    this.jianpuNumber,
    this.jianpuOctaveDots,
    this.jianpuAccidentalSharp,
    this.fingerString,
    this.fingerNumber,
  });

  NoteEvent copyWith({
    String? pitch,
    int? midiNumber,
    int? octave,
    NoteValue? noteValue,
    bool? dotted,
    bool? isRest,
    int? scoreFinger,
    String? displayAccidental,
    int? jianpuNumber,
    int? jianpuOctaveDots,
    bool? jianpuAccidentalSharp,
    String? fingerString,
    String? fingerNumber,
  }) =>
      NoteEvent(
        pitch: pitch ?? this.pitch,
        midiNumber: midiNumber ?? this.midiNumber,
        octave: octave ?? this.octave,
        noteValue: noteValue ?? this.noteValue,
        dotted: dotted ?? this.dotted,
        isRest: isRest ?? this.isRest,
        scoreFinger: scoreFinger ?? this.scoreFinger,
        displayAccidental: displayAccidental ?? this.displayAccidental,
        jianpuNumber: jianpuNumber ?? this.jianpuNumber,
        jianpuOctaveDots: jianpuOctaveDots ?? this.jianpuOctaveDots,
        jianpuAccidentalSharp:
            jianpuAccidentalSharp ?? this.jianpuAccidentalSharp,
        fingerString: fingerString ?? this.fingerString,
        fingerNumber: fingerNumber ?? this.fingerNumber,
      );
}

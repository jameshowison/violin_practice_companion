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
    this.jianpuNumber,
    this.jianpuOctaveDots,
    this.jianpuAccidentalSharp,
    this.fingerString,
    this.fingerNumber,
  });

  NoteEvent copyWith({
    int? jianpuNumber,
    int? jianpuOctaveDots,
    bool? jianpuAccidentalSharp,
    String? fingerString,
    String? fingerNumber,
  }) =>
      NoteEvent(
        pitch: pitch,
        midiNumber: midiNumber,
        octave: octave,
        noteValue: noteValue,
        dotted: dotted,
        isRest: isRest,
        scoreFinger: scoreFinger,
        jianpuNumber: jianpuNumber ?? this.jianpuNumber,
        jianpuOctaveDots: jianpuOctaveDots ?? this.jianpuOctaveDots,
        jianpuAccidentalSharp:
            jianpuAccidentalSharp ?? this.jianpuAccidentalSharp,
        fingerString: fingerString ?? this.fingerString,
        fingerNumber: fingerNumber ?? this.fingerNumber,
      );
}

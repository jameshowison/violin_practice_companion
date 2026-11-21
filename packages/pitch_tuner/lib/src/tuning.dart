import 'dart:math' as math;

/// How an instrument's open strings relate to one another.
enum Temperament {
  /// Twelve-tone equal temperament: each string at its piano pitch. Right for
  /// fretted instruments (mandolin, guitar), whose frets are equal-tempered.
  equal,

  /// Pure 3:2 fifths up and down from the A string, as string players tune
  /// by ear. Against A = 440 this puts a violin's G at 195.56 Hz, about 4
  /// cents under its equal-tempered 196.00.
  pureFifths,
}

const _names = ['C', 'C♯', 'D', 'E♭', 'E', 'F', 'F♯', 'G', 'A♭', 'A', 'B♭', 'B'];

/// Scientific pitch name of a MIDI note, such as `G3` for 55.
String midiNoteName(int midi) => '${_names[midi % 12]}${midi ~/ 12 - 1}';

/// The equal-tempered frequency of a MIDI note, from a reference A4.
double midiToHz(num midi, {double a4 = 440}) =>
    a4 * math.pow(2, (midi - 69) / 12).toDouble();

/// The interval from [targetHz] to [hz], in cents: negative is flat.
double centsBetween(double hz, double targetHz) =>
    1200 * math.log(hz / targetHz) / math.ln2;

/// One open string and its target frequency.
class TunedString {
  const TunedString(this.midi, this.hz);

  final int midi;
  final double hz;

  /// Scientific pitch name, such as `G3`.
  String get name => midiNoteName(midi);

  @override
  String toString() => '$name ${hz.toStringAsFixed(2)} Hz';
}

/// An instrument's open strings, lowest first, at a reference pitch.
class InstrumentTuning {
  InstrumentTuning({
    required this.name,
    required List<int> openStrings,
    required this.temperament,
    this.a4 = 440,
  }) : strings = List.unmodifiable(_targets(openStrings, temperament, a4));

  /// Violin: G3 D4 A4 E5 in pure fifths.
  factory InstrumentTuning.violin({double a4 = 440}) => InstrumentTuning(
      name: 'Violin', openStrings: const [55, 62, 69, 76],
      temperament: Temperament.pureFifths, a4: a4);

  /// Viola: C3 G3 D4 A4 in pure fifths.
  factory InstrumentTuning.viola({double a4 = 440}) => InstrumentTuning(
      name: 'Viola', openStrings: const [48, 55, 62, 69],
      temperament: Temperament.pureFifths, a4: a4);

  /// Cello: C2 G2 D3 A3 in pure fifths.
  factory InstrumentTuning.cello({double a4 = 440}) => InstrumentTuning(
      name: 'Cello', openStrings: const [36, 43, 50, 57],
      temperament: Temperament.pureFifths, a4: a4);

  /// Mandolin: G3 D4 A4 E5, the violin's notes, equal-tempered. Each is a
  /// pair of strings in unison; tune them one at a time.
  factory InstrumentTuning.mandolin({double a4 = 440}) => InstrumentTuning(
      name: 'Mandolin', openStrings: const [55, 62, 69, 76],
      temperament: Temperament.equal, a4: a4);

  final String name;
  final Temperament temperament;

  /// The reference A4, in hertz: usually 440, often 442 in orchestras.
  final double a4;

  final List<TunedString> strings;

  /// A frequency range for the detector that covers every string with room
  /// for a badly flat or sharp one: a fifth below the lowest, an octave
  /// above the highest.
  ({double minHz, double maxHz}) get detectionRange =>
      (minHz: strings.first.hz / 1.5, maxHz: strings.last.hz * 2);

  /// The string nearest [hz] in cents.
  TunedString nearest(double hz) {
    var best = strings.first;
    var bestCents = centsBetween(hz, best.hz).abs();
    for (final s in strings.skip(1)) {
      final c = centsBetween(hz, s.hz).abs();
      if (c < bestCents) {
        best = s;
        bestCents = c;
      }
    }
    return best;
  }

  static List<TunedString> _targets(List<int> midi, Temperament t, double a4) {
    if (midi.isEmpty) throw ArgumentError.value(midi, 'openStrings', 'is empty');
    if (t == Temperament.equal) {
      return [for (final m in midi) TunedString(m, midiToHz(m, a4: a4))];
    }
    // Pure fifths, anchored on the string that is an A (pitch class 9) at
    // its equal-tempered pitch from a4.
    final anchor = midi.firstWhere((m) => m % 12 == 9,
        orElse: () => throw ArgumentError.value(
            midi, 'openStrings', 'pure fifths need an A string to anchor on'));
    final anchorHz = midiToHz(anchor, a4: a4);
    return [
      for (final m in midi)
        if ((m - anchor) % 7 != 0)
          throw ArgumentError.value(
              midi, 'openStrings', 'are not all a whole number of fifths apart')
        else
          TunedString(m, anchorHz * math.pow(1.5, (m - anchor) ~/ 7).toDouble())
    ];
  }
}

/// A reading against a string: which string, and how far off.
class StringReading {
  const StringReading(this.string, this.hz, this.cents);

  final TunedString string;
  final double hz;

  /// Negative is flat.
  final double cents;
}

/// Follows which string is being played, without flickering between strings
/// on a single stray reading.
///
/// A new string takes over only after it has been the nearest for
/// [switchAfter] readings in a row. The default, 12, is about 130 ms at a
/// `PitchTracker` hop of 512 samples at 48 kHz: long enough to ignore a
/// brush of the neighbouring string (a stray 80 ms one switched strings at
/// 3), short enough not to be noticed when the player moves on. Scale it if
/// the hop or sample rate differs. A string can be pinned with [pinned],
/// as when the player picks it on screen.
class StringFollower {
  StringFollower(this.tuning, {this.switchAfter = 12});

  final InstrumentTuning tuning;
  final int switchAfter;

  /// When set, every reading is measured against this string.
  TunedString? pinned;

  TunedString? _current;
  TunedString? _candidate;
  int _count = 0;

  /// The string readings are currently measured against.
  TunedString? get current => pinned ?? _current;

  /// Measures [hz] against the followed string.
  StringReading update(double hz) {
    final pin = pinned;
    if (pin != null) return StringReading(pin, hz, centsBetween(hz, pin.hz));
    final near = tuning.nearest(hz);
    if (_current == null) {
      _current = near;
    } else if (near.midi == _current!.midi) {
      _candidate = null;
      _count = 0;
    } else {
      if (_candidate?.midi == near.midi) {
        _count++;
      } else {
        _candidate = near;
        _count = 1;
      }
      if (_count >= switchAfter) {
        _current = near;
        _candidate = null;
        _count = 0;
      }
    }
    return StringReading(_current!, hz, centsBetween(hz, _current!.hz));
  }

  /// Forgets the followed string (not [pinned]).
  void reset() {
    _current = null;
    _candidate = null;
    _count = 0;
  }
}

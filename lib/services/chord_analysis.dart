import '../models/note_event.dart' show KeyMode;

/// Diatonic analysis of a chord within a key — the scale-degree roman numeral
/// (I, IV, V, vi, ♭VII, V7, vii°…). Case follows the chord's triad quality
/// (upper = major/aug, lower = minor/dim); a ♯/♭ prefix marks a chromatic root,
/// and `°`/`+`/`7` mark the quality/extension.
class ChordAnalysis {
  static const _alpha = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
  static const _letterPc = {
    'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11,
  };
  // Tonic letter reached after `fifths` steps round the circle of fifths.
  static const _letterByFifths = ['C', 'G', 'D', 'A', 'E', 'B', 'F'];
  static const _romans = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'];
  static const _majorSteps = [0, 2, 4, 5, 7, 9, 11];
  static const _minorSteps = [0, 2, 3, 5, 7, 8, 10]; // natural minor

  /// Returns the roman numeral for [chordName] in the key given by [keyFifths]
  /// and [keyMode], or null if the name can't be parsed.
  static String? romanNumeral({
    required int keyFifths,
    required KeyMode keyMode,
    required String chordName,
  }) {
    if (chordName.isEmpty) return null;
    final rootLetter = chordName[0].toUpperCase();
    if (!_letterPc.containsKey(rootLetter)) return null;

    // Root accidentals.
    int i = 1, rootAlter = 0;
    while (i < chordName.length && (chordName[i] == '#' || chordName[i] == 'b')) {
      rootAlter += chordName[i] == '#' ? 1 : -1;
      i++;
    }
    final quality = chordName.substring(i);
    final isDim = quality.startsWith('dim') || quality.startsWith('°') ||
        quality == 'm7b5';
    final isAug = quality.startsWith('aug') || quality.startsWith('+');
    final isMinor =
        !isDim && !isAug && quality.startsWith('m') && !quality.startsWith('maj');
    final hasSeventh = quality.contains('7');

    // Tonic letter + pitch class.
    final majorTonicLetter = _letterByFifths[(keyFifths % 7 + 7) % 7];
    final majorTonicPc = (keyFifths * 7) % 12;
    final tonicLetter = keyMode == KeyMode.minor
        ? _alpha[(_alpha.indexOf(majorTonicLetter) - 2 + 7) % 7]
        : majorTonicLetter;
    final tonicPc = keyMode == KeyMode.minor
        ? (majorTonicPc - 3 + 12) % 12
        : (majorTonicPc + 12) % 12;

    // Scale-step degree (1..7) from letter distance.
    final degIdx =
        (_alpha.indexOf(rootLetter) - _alpha.indexOf(tonicLetter) + 7) % 7;
    var roman = _romans[degIdx];

    // Chromatic prefix: compare the root's pitch class to the diatonic degree.
    final steps = keyMode == KeyMode.minor ? _minorSteps : _majorSteps;
    final expectedPc = (tonicPc + steps[degIdx]) % 12;
    final actualPc = (_letterPc[rootLetter]! + rootAlter + 120) % 12;
    final diff = (actualPc - expectedPc + 12) % 12;
    final prefix = switch (diff) {
      0 => '',
      1 => '♯',
      2 => '♯♯',
      11 => '♭',
      10 => '♭♭',
      _ => '',
    };

    if (isMinor || isDim) roman = roman.toLowerCase();
    final suffix = (isDim ? '°' : (isAug ? '+' : '')) + (hasSeventh ? '7' : '');
    return '$prefix$roman$suffix';
  }
}

import 'package:flutter/painting.dart';

import '../services/chord_analysis.dart';
import 'parsed_piece.dart';
import 'section.dart';

/// One color per **scale degree**, fixed across every piece — so the tonic looks
/// the same in every tune and the color itself becomes a piece of harmonic
/// information. This is the deliberate opposite of `SectionPalette`, whose hues
/// are assigned per piece in first-appearance order; the two palettes must stay
/// visually distinct because both appear on the staff at once.
///
/// Quality shades the hue rather than changing it: a minor or diminished chord
/// takes its degree's color dimmed (see [of]), so `iv` reads as a darker `IV`
/// rather than as an unrelated color.
class ChordPalette {
  ChordPalette._();

  /// Degree index (0 = I … 6 = VII) → base hue, at major quality.
  static const byDegree = <Color>[
    Color(0xFFE8DCC0), // I   parchment — home, deliberately the quietest
    Color(0xFF4C9A5A), // II  green
    Color(0xFF4C9A5A), // III green, hatched with [iiiAlt] — see [hatchedDegree]
    Color(0xFFC4443A), // IV  red
    Color(0xFFE8C33E), // V   yellow
    Color(0xFF4A7BC8), // VI  blue
    Color(0xFFE08A3C), // VII orange
  ];

  /// III pulls towards II in some contexts and IV in others, and is rare enough
  /// in this repertoire that picking a side would be arbitrary — so it is drawn
  /// as diagonal hashes of [byDegree]`[2]` (green) over this red.
  static const iiiAlt = Color(0xFFC4443A);

  /// The one degree drawn as a hatch rather than a flat fill.
  static const hatchedDegree = 2;

  /// A chord whose name we couldn't analyze against the key.
  static const unknown = Color(0xFF9E9E9E);

  /// [degree]'s color, dimmed when the chord's quality is minor/diminished.
  ///
  /// The dim is an HSL move (lightness ×[_dimLightness], saturation
  /// ×[_dimSaturation]) rather than an alpha reduction or a second hard-coded
  /// table: alpha would blend the bar into whatever it happens to sit on, and
  /// deriving the shade guarantees the pair stays the same hue.
  static Color of(int? degree, {bool minor = false}) {
    final base = (degree == null || degree < 0 || degree >= byDegree.length)
        ? unknown
        : byDegree[degree];
    return minor ? dim(base) : base;
  }

  /// The minor/diminished shade of [c]. Public so the hatch's second color and
  /// the footer accents dim in step with the bars.
  static Color dim(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness * _dimLightness).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation * _dimSaturation).clamp(0.0, 1.0))
        .toColor();
  }

  static const _dimLightness = 0.62;
  static const _dimSaturation = 0.85;

  /// Readable label color on a bar filled with [fill] — the palette spans
  /// parchment to blue, so neither black nor white works for all of it.
  static Color inkOn(Color fill) => fill.computeLuminance() > 0.45
      ? const Color(0xFF1A1A1A)
      : const Color(0xFFFFFFFF);
}

/// One chord's span over the engraved (folded) score, with note-level edges so a
/// chord that changes mid-measure colors only its own notes.
///
/// Coordinates are engraved measure INDICES (matching the staff's
/// `measureNumbers` list), exactly as for `SectionTintRegion`: [startNote] is the
/// first governed note in [startMeasureIndex] (0 = bar start); [endNote] is the
/// EXCLUSIVE last note in [endMeasureIndex] (`-1` = the whole [endMeasureIndex]).
typedef ChordRunRegion = ({
  int startMeasureIndex,
  int startNote,
  int endMeasureIndex,
  int endNote,
  String label, // "I (A)" — degree-primary, matching the engraver's _harmLabel
  int? degree, // 0..6, or null when the chord name won't analyze
  bool minorQuality, // picks the dimmer shade of [degree]'s hue
});

/// Builds one region per chord run over the folded staff. [measureNumbers] is the
/// engraved order (index → measure number).
///
/// A chord run has the same shape as a section run — a marker that holds until
/// the next marker, at note-level granularity — so the boundary resolution is
/// delegated to [resolveSectionRanges] rather than re-derived. Measures before
/// the first chord are covered by no region.
List<ChordRunRegion> chordRunRegions(
    List<int> measureNumbers, ParsedPiece parsed) {
  // Chord starts as markers. NoteEvent.chordSymbol is non-null exactly where a
  // chord begins, so the note index IS the marker's note offset.
  final markers = <Section>[];
  for (final m in parsed.measures) {
    for (var j = 0; j < m.notes.length; j++) {
      final symbol = m.notes[j].chordSymbol;
      if (symbol != null) {
        markers.add(
            Section(label: symbol, startMeasure: m.number, startNote: j));
      }
    }
  }
  if (markers.isEmpty) return const [];

  final regions = <ChordRunRegion>[];
  for (final r in resolveSectionRanges(markers, parsed.measures)) {
    final startIdx = measureNumbers.indexOf(r.startMeasure);
    final endIdx = measureNumbers.indexOf(r.endMeasure);
    if (startIdx < 0 || endIdx < 0) continue;
    final a = ChordAnalysis.analyze(
      keyFifths: parsed.keyFifths,
      keyMode: parsed.keyMode,
      chordName: r.label,
    );
    regions.add((
      startMeasureIndex: startIdx,
      startNote: r.startNote,
      endMeasureIndex: endIdx,
      endNote: r.endNote,
      // Degree-primary, matching how the symbol used to be engraved.
      label: a == null ? r.label : '${a.roman} (${r.label})',
      degree: a?.degreeIndex,
      minorQuality: a?.minorQuality ?? false,
    ));
  }
  return regions;
}

import 'package:flutter/painting.dart';
import 'parsed_piece.dart';
import 'section.dart';

/// One low-saturation color per section, the shared visual identity across the
/// staff wash, the jianpu/fingering section bands, and the minimap emblems.
///
/// Colors are assigned to *distinct labels* in first-appearance order, so every
/// occurrence of a repeated section (both `A`s in ABAA) shares one color.
class SectionPalette {
  /// Base hues — distinct but muted. Applied at low alpha as backgrounds so they
  /// never fight the notation; used near-full strength for minimap emblems.
  static const swatches = <Color>[
    Color(0xFF5B8DEF), // blue
    Color(0xFF57B894), // green
    Color(0xFFE0A33E), // amber
    Color(0xFF9B7EDE), // violet
    Color(0xFFE07A8B), // rose
    Color(0xFF4FB0C6), // teal
    Color(0xFFB0884F), // tan
  ];

  /// Label → base color, by first-appearance order across [sections].
  static Map<String, Color> colorsForSections(List<Section> sections) {
    final map = <String, Color>{};
    var i = 0;
    for (final s in sections) {
      map.putIfAbsent(s.label, () => swatches[i++ % swatches.length]);
    }
    return map;
  }

  /// `#rrggbb` for the OSMD bridge (which applies its own low opacity).
  static String hex(Color c) =>
      '#${(c.toARGB32() & 0x00FFFFFF).toRadixString(16).padLeft(6, '0')}';
}

/// A section's background-wash region over the engraved (folded) score, with
/// note-level edges so a section that begins/ends mid-measure colors only its
/// notes. Coordinates are engraved measure INDICES (matching the staff's
/// `measureNumbers` list). [startNote] is the first tinted note in
/// [startMeasureIndex] (0 = bar start); [endNote] is the EXCLUSIVE last note in
/// [endMeasureIndex] (`-1` = the whole [endMeasureIndex]).
typedef SectionTintRegion = ({
  int startMeasureIndex,
  int startNote,
  int endMeasureIndex,
  int endNote,
  String color,
});

/// Builds per-section wash regions over the folded staff. [measureNumbers] is
/// the engraved order (index → measure number); [measures] is the parsed
/// measure list (for resolving marker note offsets); [colors] maps label → hue.
/// Sections sharing a label share a color (so A/B yield two colors).
List<SectionTintRegion> sectionTintRegions(
  List<int> measureNumbers,
  List<Section> sections,
  Map<String, Color> colors,
  List<Measure> measures,
) {
  final ranges = resolveSectionRanges(sections, measures);
  const fallback = Color(0xFF888888);
  final regions = <SectionTintRegion>[];
  for (final r in ranges) {
    final startIdx = measureNumbers.indexOf(r.startMeasure);
    final endIdx = measureNumbers.indexOf(r.endMeasure);
    if (startIdx < 0 || endIdx < 0) continue;
    regions.add((
      startMeasureIndex: startIdx,
      startNote: r.startNote,
      endMeasureIndex: endIdx,
      endNote: r.endNote,
      color: SectionPalette.hex(colors[r.label] ?? fallback),
    ));
  }
  return regions;
}

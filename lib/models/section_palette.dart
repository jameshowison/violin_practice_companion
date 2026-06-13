import 'package:flutter/painting.dart';
import 'section.dart';

/// One low-saturation color per section, the shared visual identity across the
/// staff wash, the jianpu/fingering section bands, and the minimap emblems.
///
/// Colors are assigned to *distinct labels* in first-appearance order, so every
/// occurrence of a repeated section (both `A`s in ABAA mode) shares one color.
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

/// Contiguous measure-index span sharing one section color — what the OSMD
/// bridge's `setSectionTints` draws as the per-section background wash.
typedef SectionTintSpan = ({int start, int end, String color});

/// Groups [measureNumbers] (the staff's possibly-unfolded order) into contiguous
/// same-section index spans, each tagged with its label's palette hex. Measures
/// outside any section (e.g. a pickup) are left untinted (no span).
List<SectionTintSpan> sectionTintSpans(
  List<int> measureNumbers,
  List<Section> sections,
  Map<String, Color> colors,
) {
  String? labelFor(int n) {
    for (final s in sections) {
      if (n >= s.startMeasure && n <= s.endMeasure) return s.label;
    }
    return null;
  }

  const fallback = Color(0xFF888888);
  final spans = <SectionTintSpan>[];
  String? cur;
  var start = 0;
  void close(int endExclusive) {
    if (cur != null) {
      spans.add((
        start: start,
        end: endExclusive - 1,
        color: SectionPalette.hex(colors[cur] ?? fallback),
      ));
    }
  }

  for (var i = 0; i < measureNumbers.length; i++) {
    final lbl = labelFor(measureNumbers[i]);
    if (lbl != cur) {
      close(i);
      cur = lbl;
      start = i;
    }
  }
  close(measureNumbers.length);
  return spans;
}

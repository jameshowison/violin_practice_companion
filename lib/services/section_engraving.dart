import 'dart:math' as math;

import 'section_line_planner.dart';
import 'staff_zoom.dart';
import 'system_break_injector.dart';

/// The section layout's decisions, short of engraving them: where each section
/// breaks into lines, and the scale that makes the widest planned line fill
/// the width.
///
/// Shared by the on-screen staff (`StaffViewVerovio`, whose floor is the
/// device's [minStaffScaleFor]) and print (`score_printer.dart`, whose floor
/// is a physical staff height on paper), so the two lay a piece out by the
/// same rule and differ only in how big the notes may be.
///
/// * [musicXml] — the xml already broken before every section
///   (`insertSystemBreaks`), as the engrave will receive it.
/// * [naturalWidths] — every engraved measure's natural width in MEI units,
///   from one unjustified single-line engrave (see [sectionNaturalLineWidthPx]).
/// * [minScale] — the smallest acceptable staff size, which fixes how wide a
///   line may be.
/// * [linesPerSection] — the user's lines-per-section zoom, or null for the
///   fewest that fit.
///
/// The returned [xml] carries the planned breaks; engrave it with
/// `breaks: 'encoded'` at [scale] and [minLastJustification].
({String xml, double scale, int lines, int maxLines, Set<int> breaks,
    double widestUnits, double? minLastJustification}) solveSectionLayout({
  required String musicXml,
  required List<double> naturalWidths,
  required double widthPx,
  required double minScale,
  double maxScale = staffScaleMax,
  int? linesPerSection,
}) {
  final usableUnits =
      (widthPx * 100 / minScale - sectionPageMarginUnits) / staffFitSlack;
  final starts = systemStartPositions(musicXml);
  final plan = planSectionLines(
    widths: naturalWidths,
    segmentStarts: starts,
    maxLineUnits: usableUnits - sectionLineStartUnits,
    lines: linesPerSection,
  );
  final scale = (widthPx *
          100 /
          ((plan.widestUnits + sectionLineStartUnits) * staffFitSlack +
              sectionPageMarginUnits))
      .clamp(staffScaleMin, maxScale);
  final lineStarts = {...starts, ...plan.breaks, 0}
      .where((s) => s < naturalWidths.length)
      .toList()
    ..sort();
  final lineUnits = [
    for (var i = 0; i < lineStarts.length; i++)
      naturalWidths
              .sublist(lineStarts[i],
                  i + 1 < lineStarts.length ? lineStarts[i + 1] : naturalWidths.length)
              .fold(0.0, (a, b) => a + b) +
          sectionLineStartUnits,
  ];
  final justify = justifyLastSectionLine(
    lineUnits: lineUnits,
    pageUnits: widthPx * 100 / scale - sectionPageMarginUnits,
  );
  return (
    xml: insertBreaksAtPositions(musicXml, plan.breaks),
    scale: scale,
    lines: starts.length + plan.breaks.length,
    maxLines: plan.maxLines,
    breaks: plan.breaks,
    widestUnits: plan.widestUnits,
    minLastJustification: justify == null ? null : (justify ? 0.0 : 1.0),
  );
}

/// Whether the section layout's LAST line should be stretched to the full
/// width, so that its notes sit about as far apart as everyone else's.
///
/// Verovio justifies every system but the last, and the last only when it
/// fills 80% of the page (`minLastJustification`). So every other line is
/// stretched by `pageUnits / its natural width`, and when the solved scale is
/// clamped at its maximum (a short piece) that stretch is the same large
/// factor on every line, while the last line is left at natural spacing and
/// reads as cramped (O Come, Little Children on the SE: lines 1–3 stretched
/// ~1.27×, the last at 79% of the page and so left alone).
///
/// Verovio can only justify the last line fully or not at all, so this picks
/// whichever leaves its stretch closer to the other lines' median, compared
/// as ratios (log scale): justified it stretches by `pageUnits / last`, left
/// alone by 1.
///
/// [lineUnits] — each line's natural width in MEI units, in order.
/// [pageUnits] — the width a justified line fills, in the same units.
/// Returns null (Verovio's default) when there is no other line to match.
bool? justifyLastSectionLine({
  required List<double> lineUnits,
  required double pageUnits,
}) {
  if (lineUnits.length < 2 || pageUnits <= 0) return null;
  final last = lineUnits.last;
  if (last <= 0) return null;
  final others = [
    for (final w in lineUnits.take(lineUnits.length - 1))
      if (w > 0) math.max(1.0, pageUnits / w),
  ]..sort();
  if (others.isEmpty) return null;
  final ref = others[others.length ~/ 2];
  final justified = math.max(1.0, pageUnits / last);
  // |ln(justified) - ln(ref)| < |ln(1) - ln(ref)|
  return (math.log(justified) - math.log(ref)).abs() < math.log(ref).abs();
}

/// Wide enough that the natural-width engrave keeps the whole piece on one
/// line: 39000px at the probe's scale is a 97500-unit page, just inside
/// Verovio's 100000 maximum. Verovio leaves a last (here: only) system
/// unjustified while it fills under 80% of the page, so the widths are
/// natural ones for any piece under ~200 bars.
const double sectionNaturalLineWidthPx = 39000.0;

/// Verovio's default left + right page margins, in MEI units.
const double sectionPageMarginUnits = 100.0;

/// What every line spends before its first note that no measure's natural
/// width includes: the restated key signature (clef and time are hidden at
/// each break — see `insertSystemBreaks`).
const double sectionLineStartUnits = 60.0;

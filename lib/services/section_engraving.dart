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
/// `breaks: 'encoded'` at [scale].
({String xml, double scale, int lines, int maxLines, Set<int> breaks,
    double widestUnits}) solveSectionLayout({
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
  return (
    xml: insertBreaksAtPositions(musicXml, plan.breaks),
    scale: scale,
    lines: starts.length + plan.breaks.length,
    maxLines: plan.maxLines,
    breaks: plan.breaks,
    widestUnits: plan.widestUnits,
  );
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

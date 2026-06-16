import 'package:flutter/material.dart';
import '../models/parsed_piece.dart';
import '../models/section.dart';
import '../services/providers.dart';

/// Horizontal strip of section chips (`A: 1–8`) for whole-section range
/// selection. Section bounds are resolved from the start markers + [measures]
/// (a section runs to the next marker), so a mid-measure start still selects
/// whole measures here.
class SectionBar extends StatelessWidget {
  final List<Section> sections;
  final List<Measure> measures;
  final MeasureSelection? selection;
  final ValueChanged<MeasureSelection> onSectionTap;

  const SectionBar({
    super.key,
    required this.sections,
    required this.measures,
    required this.selection,
    required this.onSectionTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ranges = resolveSectionRanges(sections, measures);
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: ranges.map((r) {
          final isActive = selection != null &&
              selection!.startMeasure == r.startMeasure &&
              selection!.endMeasure == r.endMeasure;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: GestureDetector(
              onTap: () =>
                  onSectionTap(MeasureSelection(r.startMeasure, r.endMeasure)),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${r.label}: ${r.startMeasure}–${r.endMeasure}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isActive
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

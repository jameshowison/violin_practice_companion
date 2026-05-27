import 'package:flutter/material.dart';
import '../models/section.dart';
import '../services/providers.dart';

class SectionBar extends StatelessWidget {
  final List<Section> sections;
  final MeasureSelection? selection;
  final ValueChanged<MeasureSelection> onSectionTap;

  const SectionBar({
    super.key,
    required this.sections,
    required this.selection,
    required this.onSectionTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: sections.map((s) {
          final isActive = selection != null &&
              selection!.startMeasure == s.startMeasure &&
              selection!.endMeasure == s.endMeasure;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: GestureDetector(
              onTap: () =>
                  onSectionTap(MeasureSelection(s.startMeasure, s.endMeasure)),
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
                  '${s.label}: ${s.startMeasure}–${s.endMeasure}',
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

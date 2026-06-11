import 'package:flutter/material.dart';
import '../models/section.dart';
import '../services/providers.dart';

class MeasureSelector extends StatefulWidget {
  final int measureCount;
  final List<Section> sections;
  final MeasureSelection? selection;
  final ValueChanged<MeasureSelection?> onSelectionChanged;
  final int? activeMeasure;

  /// Measure numbers whose beat total doesn't match the time signature
  /// (likely an OMR error). Flagged tiles get a small warning glyph.
  final Set<int>? flaggedMeasures;

  const MeasureSelector({
    super.key,
    required this.measureCount,
    required this.sections,
    required this.selection,
    required this.onSelectionChanged,
    this.activeMeasure,
    this.flaggedMeasures,
  });

  @override
  State<MeasureSelector> createState() => _MeasureSelectorState();
}

class _MeasureSelectorState extends State<MeasureSelector> {
  void _handleTap(int measure) {
    final sel = widget.selection;
    if (sel != null && sel.startMeasure == measure && sel.endMeasure == measure) {
      widget.onSelectionChanged(null);
    } else {
      widget.onSelectionChanged(MeasureSelection(measure, measure));
    }
  }

  Map<int, String> _sectionLabelForMeasure() {
    final map = <int, String>{};
    for (final s in widget.sections) {
      map[s.startMeasure] = s.label;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final sectionLabels = _sectionLabelForMeasure();
    final theme = Theme.of(context);

    return SizedBox(
      height: 52,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: widget.measureCount,
        itemBuilder: (context, index) {
          final measure = index + 1;
          final isSelected = widget.selection?.contains(measure) ?? false;
          final isActive = widget.activeMeasure == measure;
          final isFlagged = widget.flaggedMeasures?.contains(measure) ?? false;
          final label = sectionLabels[measure];

          return GestureDetector(
            onTap: () => _handleTap(measure),
            child: Stack(
              children: [
                Container(
                  width: 32,
                  margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
                  decoration: BoxDecoration(
                    color: isActive
                        ? Colors.amber
                        : isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (label != null)
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: isActive || isSelected
                                ? theme.colorScheme.onPrimary
                                : Colors.blueGrey,
                          ),
                        ),
                      Text(
                        '$measure',
                        style: TextStyle(
                          fontSize: 11,
                          color: isActive || isSelected
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isFlagged)
                  const Positioned(
                    top: 0,
                    right: 1,
                    child: Icon(Icons.warning_amber_rounded,
                        size: 12, color: Colors.deepOrange),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

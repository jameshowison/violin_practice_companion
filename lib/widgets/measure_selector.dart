import 'package:flutter/material.dart';
import '../models/section.dart';
import '../services/providers.dart';

class MeasureSelector extends StatefulWidget {
  final int measureCount;
  final List<Section> sections;
  final MeasureSelection? selection;
  final ValueChanged<MeasureSelection?> onSelectionChanged;
  final int? activeMeasure;

  const MeasureSelector({
    super.key,
    required this.measureCount,
    required this.sections,
    required this.selection,
    required this.onSelectionChanged,
    this.activeMeasure,
  });

  @override
  State<MeasureSelector> createState() => _MeasureSelectorState();
}

class _MeasureSelectorState extends State<MeasureSelector> {
  int? _dragStart;

  void _handleTap(int measure) {
    final sel = widget.selection;
    if (sel != null && sel.startMeasure == measure && sel.endMeasure == measure) {
      widget.onSelectionChanged(null);
    } else {
      widget.onSelectionChanged(MeasureSelection(measure, measure));
    }
  }

  void _handleDragStart(int measure) {
    _dragStart = measure;
  }

  void _handleDragUpdate(int measure) {
    if (_dragStart == null) return;
    final start = _dragStart! < measure ? _dragStart! : measure;
    final end = _dragStart! < measure ? measure : _dragStart!;
    widget.onSelectionChanged(MeasureSelection(start, end));
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
          final label = sectionLabels[measure];

          return GestureDetector(
            onTap: () => _handleTap(measure),
            onHorizontalDragStart: (_) => _handleDragStart(measure),
            onHorizontalDragUpdate: (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final local = box.globalToLocal(details.globalPosition);
              const itemWidth = 32.0;
              final idx = (local.dx / itemWidth).floor();
              final clamped = idx.clamp(0, widget.measureCount - 1);
              _handleDragUpdate(clamped + 1);
            },
            child: Container(
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
          );
        },
      ),
    );
  }
}

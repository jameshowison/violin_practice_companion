import 'package:flutter/material.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece_layout.dart';
import 'notation_layout_engine.dart';

class FingeringView extends StatelessWidget {
  final PieceLayout layout;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final bool combined;

  const FingeringView({
    super.key,
    required this.layout,
    required this.selectedMeasures,
    required this.sectionLabels,
    this.onMeasureTap,
    this.combined = false,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: layout.rows.map((row) {
          return _FingeringRow(
            measures: row,
            selectedMeasures: selectedMeasures,
            sectionLabels: sectionLabels,
            onMeasureTap: onMeasureTap,
            combined: combined,
          );
        }).toList(),
      ),
    );
  }
}

class _FingeringRow extends StatelessWidget {
  final List<Measure> measures;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final bool combined;

  const _FingeringRow({
    required this.measures,
    required this.selectedMeasures,
    required this.sectionLabels,
    this.onMeasureTap,
    required this.combined,
  });

  @override
  Widget build(BuildContext context) {
    final rowH = combined
        ? NotationLayout.rowHeight + 20.0
        : NotationLayout.rowHeight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < measures.length; i++) ...[
              _FingeringMeasure(
                measure: measures[i],
                isSelected: selectedMeasures.contains(measures[i].number),
                sectionLabel: sectionLabels[measures[i].number],
                onTap: () => onMeasureTap?.call(measures[i].number),
                combined: combined,
                rowHeight: rowH,
              ),
              if (i < measures.length - 1)
                Container(
                  width: NotationLayout.barlineWidth,
                  height: rowH + 16,
                  color: Colors.black87,
                  margin: const EdgeInsets.only(top: 16),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FingeringMeasure extends StatelessWidget {
  final Measure measure;
  final bool isSelected;
  final String? sectionLabel;
  final VoidCallback? onTap;
  final bool combined;
  final double rowHeight;

  const _FingeringMeasure({
    required this.measure,
    required this.isSelected,
    this.sectionLabel,
    this.onTap,
    required this.combined,
    required this.rowHeight,
  });

  @override
  Widget build(BuildContext context) {
    final width = NotationLayout.measureWidth(measure);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primaryContainer.withAlpha(180)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 16,
              child: sectionLabel != null
                  ? Text(
                      sectionLabel!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                    )
                  : null,
            ),
            SizedBox(
              height: rowHeight,
              child: CustomPaint(
                size: Size(width, rowHeight),
                painter: _FingeringMeasurePainter(
                  notes: measure.notes,
                  combined: combined,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FingeringMeasurePainter extends CustomPainter {
  final List<NoteEvent> notes;
  final bool combined;

  _FingeringMeasurePainter({required this.notes, required this.combined});

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    const baseY = 28.0;

    double x = 0.0;
    for (final note in notes) {
      final nw = NotationLayout.noteWidth(note);
      final centerX = x + nw / 2;

      if (combined) {
        final num = note.isRest ? '0' : '${note.jianpuNumber ?? "?"}';
        _drawText(canvas, tp, num, centerX, baseY - 12, fontSize: 14);
      }

      if (note.isRest) {
        _drawText(canvas, tp, '-', centerX, combined ? baseY + 10 : baseY,
            fontSize: 14);
      } else {
        final fs = note.fingerString ?? '?';
        final fn = note.fingerNumber ?? '?';
        _drawFingeringLabel(canvas, tp, fs, fn, centerX,
            combined ? baseY + 10 : baseY);
      }
      x += nw;
    }
  }

  void _drawFingeringLabel(Canvas canvas, TextPainter tp, String str,
      String finger, double cx, double cy) {
    final isLow = finger.endsWith('low');
    final baseFinger = isLow ? finger.replaceAll('low', '') : finger;
    _drawText(canvas, tp, '$str$baseFinger', cx, cy, fontSize: 15);
    if (isLow) {
      _drawText(canvas, tp, 'b', cx + 10, cy + 4, fontSize: 9);
    }
  }

  void _drawText(Canvas canvas, TextPainter tp, String text, double cx,
      double cy, {required double fontSize}) {
    tp.text = TextSpan(
      text: text,
      style: TextStyle(fontSize: fontSize, color: Colors.black),
    );
    tp.layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _FingeringMeasurePainter old) =>
      old.notes != notes || old.combined != combined;
}

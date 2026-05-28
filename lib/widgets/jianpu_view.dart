import 'package:flutter/material.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece_layout.dart';
import 'notation_layout_engine.dart';

class JianpuView extends StatelessWidget {
  final PieceLayout layout;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final String? keySignature;
  final int? activeMeasure;

  const JianpuView({
    super.key,
    required this.layout,
    required this.selectedMeasures,
    required this.sectionLabels,
    this.onMeasureTap,
    this.keySignature,
    this.activeMeasure,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          if (keySignature != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text(
                '1 = $keySignature',
                style: const TextStyle(
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                  color: Colors.black87,
                ),
              ),
            ),
          ...layout.rows.map((row) => _JianpuRow(
                measures: row,
                selectedMeasures: selectedMeasures,
                sectionLabels: sectionLabels,
                onMeasureTap: onMeasureTap,
                activeMeasure: activeMeasure,
              )),
        ],
      ),
    );
  }
}

class _JianpuRow extends StatelessWidget {
  final List<Measure> measures;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final int? activeMeasure;

  const _JianpuRow({
    required this.measures,
    required this.selectedMeasures,
    required this.sectionLabels,
    this.onMeasureTap,
    this.activeMeasure,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < measures.length; i++) ...[
              _JianpuMeasure(
                measure: measures[i],
                isSelected: selectedMeasures.contains(measures[i].number),
                isActive: activeMeasure == measures[i].number,
                sectionLabel: sectionLabels[measures[i].number],
                onTap: () => onMeasureTap?.call(measures[i].number),
              ),
              if (i < measures.length - 1)
                Container(
                  width: NotationLayout.barlineWidth,
                  height: NotationLayout.rowHeight + 16,
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

class _JianpuMeasure extends StatelessWidget {
  final Measure measure;
  final bool isSelected;
  final bool isActive;
  final String? sectionLabel;
  final VoidCallback? onTap;

  const _JianpuMeasure({
    required this.measure,
    required this.isSelected,
    required this.isActive,
    this.sectionLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final width = NotationLayout.measureWidth(measure);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: isActive
              ? Colors.amber.withAlpha(140)
              : isSelected
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
              height: NotationLayout.rowHeight,
              child: CustomPaint(
                size: Size(width, NotationLayout.rowHeight),
                painter: _JianpuMeasurePainter(notes: measure.notes),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JianpuMeasurePainter extends CustomPainter {
  final List<NoteEvent> notes;

  _JianpuMeasurePainter({required this.notes});

  @override
  void paint(Canvas canvas, Size size) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    const baseY = 28.0;

    final linePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    double x = 0.0;
    for (final note in notes) {
      final nw = NotationLayout.noteWidth(note);
      final centerX = x + nw / 2;

      if (note.isRest) {
        _drawText(canvas, textPainter, '0', centerX, baseY, fontSize: 18);
        x += nw;
        continue;
      }

      final num = note.jianpuNumber ?? 0;
      final octaveDots = note.jianpuOctaveDots ?? 0;
      final sharp = note.jianpuAccidentalSharp ?? false;

      if (sharp) {
        _drawText(canvas, textPainter, '#', centerX - 10, baseY - 8, fontSize: 10);
      }

      _drawText(canvas, textPainter, '$num', centerX, baseY, fontSize: 18);

      if (octaveDots > 0) {
        for (int d = 0; d < octaveDots; d++) {
          canvas.drawCircle(
            Offset(centerX, baseY - 16 - d * 6), 2, Paint()..color = Colors.black);
        }
      } else if (octaveDots < 0) {
        for (int d = 0; d < -octaveDots; d++) {
          canvas.drawCircle(
            Offset(centerX, baseY + 14 + d * 6), 2, Paint()..color = Colors.black);
        }
      }

      final underlineCount = _underlineCount(note.noteValue);
      for (int u = 0; u < underlineCount; u++) {
        final y = baseY + 12 + u * 4;
        canvas.drawLine(Offset(x + 4, y), Offset(x + nw - 4, y), linePaint);
      }

      if (note.dotted) {
        canvas.drawCircle(
          Offset(centerX + 10, baseY + 2), 2, Paint()..color = Colors.black);
      }

      final dashCount = _dashCount(note.noteValue, note.dotted);
      for (int d = 1; d <= dashCount; d++) {
        final dashCX = x + d * NotationLayout.cellWidth + NotationLayout.cellWidth / 2;
        _drawText(canvas, textPainter, '—', dashCX, baseY, fontSize: 18);
      }

      x += nw;
    }
  }

  int _underlineCount(NoteValue v) {
    switch (v) {
      case NoteValue.eighth: return 1;
      case NoteValue.sixteenth: return 2;
      default: return 0;
    }
  }

  int _dashCount(NoteValue v, bool dotted) {
    switch (v) {
      case NoteValue.whole: return 3;
      case NoteValue.half:  return dotted ? 2 : 1;
      default: return 0;
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
  bool shouldRepaint(covariant _JianpuMeasurePainter old) => old.notes != notes;
}

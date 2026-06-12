import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece_layout.dart';
import 'notation_layout_engine.dart';

class JianpuView extends StatefulWidget {
  final PieceLayout layout;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final String? keySignature;
  final ValueNotifier<int?> Function(int measureNumber) notifierForMeasure;
  final ValueListenable<int?>? currentMeasureNotifier;

  /// Measures whose beat total doesn't match the time signature (OMR errors);
  /// flagged measures get a small warning glyph.
  final Set<int> flaggedMeasures;

  const JianpuView({
    super.key,
    required this.layout,
    required this.selectedMeasures,
    required this.sectionLabels,
    required this.notifierForMeasure,
    this.onMeasureTap,
    this.keySignature,
    this.currentMeasureNotifier,
    this.flaggedMeasures = const {},
  });

  @override
  State<JianpuView> createState() => _JianpuViewState();
}

class _JianpuViewState extends State<JianpuView> {
  final _scrollController = ScrollController();
  // Updated by LayoutBuilder each build; used by the scroll listener.
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    widget.currentMeasureNotifier?.addListener(_onMeasureChanged);
  }

  @override
  void didUpdateWidget(JianpuView old) {
    super.didUpdateWidget(old);
    if (old.currentMeasureNotifier != widget.currentMeasureNotifier) {
      old.currentMeasureNotifier?.removeListener(_onMeasureChanged);
      widget.currentMeasureNotifier?.addListener(_onMeasureChanged);
    }
  }

  @override
  void dispose() {
    widget.currentMeasureNotifier?.removeListener(_onMeasureChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onMeasureChanged() {
    final m = widget.currentMeasureNotifier?.value;
    if (m == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToMeasure(m));
  }

  void _scrollToMeasure(int measureNumber) {
    if (!_scrollController.hasClients) return;
    final rowIndex = widget.layout.rows
        .indexWhere((row) => row.any((m) => m.number == measureNumber));
    if (rowIndex < 0) return;

    // Header height: Padding(top:6,bottom:2) + Text(fontSize:14) ≈ 28pt
    final headerH = widget.keySignature != null ? 28.0 : 0.0;
    // Each row: label + note area, both scaled, plus symmetric vertical padding (2×2=4 each side → 8).
    const rowPad = 8.0;
    final rowH =
        (_JianpuMeasure.labelHeight + NotationLayout.rowHeight) * _scale +
            rowPad;

    final rowTop = headerH + rowIndex * rowH;
    final target = (rowTop - 8).clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final availableWidth = constraints.maxWidth;
      final maxRowW = widget.layout.rows.isEmpty
          ? 1.0
          : widget.layout.rows.map(NotationLayout.rowWidth).reduce(math.max);
      _scale = (availableWidth / maxRowW).clamp(0.0, 1.0);

      return SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          children: [
            if (widget.keySignature != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  '1 = ${widget.keySignature}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: Colors.black87,
                  ),
                ),
              ),
            ...widget.layout.rows.map((row) => _JianpuRow(
                  measures: row,
                  selectedMeasures: widget.selectedMeasures,
                  flaggedMeasures: widget.flaggedMeasures,
                  sectionLabels: widget.sectionLabels,
                  onMeasureTap: widget.onMeasureTap,
                  notifierForMeasure: widget.notifierForMeasure,
                  scale: _scale,
                )),
          ],
        ),
      );
    });
  }
}

class _JianpuRow extends StatelessWidget {
  final List<Measure> measures;
  final Set<int> selectedMeasures;
  final Set<int> flaggedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final ValueNotifier<int?> Function(int) notifierForMeasure;
  final double scale;

  const _JianpuRow({
    required this.measures,
    required this.selectedMeasures,
    required this.flaggedMeasures,
    required this.sectionLabels,
    required this.notifierForMeasure,
    required this.scale,
    this.onMeasureTap,
  });

  @override
  Widget build(BuildContext context) {
    final barlineH =
        (NotationLayout.rowHeight + _JianpuMeasure.labelHeight) * scale;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < measures.length; i++) ...[
              _JianpuMeasure(
                measure: measures[i],
                isSelected: selectedMeasures.contains(measures[i].number),
                isFlagged: flaggedMeasures.contains(measures[i].number),
                notifierForMeasure: notifierForMeasure,
                sectionLabel: sectionLabels[measures[i].number],
                onTap: () => onMeasureTap?.call(measures[i].number),
                scale: scale,
              ),
              if (i < measures.length - 1)
                Container(
                  width: NotationLayout.barlineWidth * scale,
                  height: barlineH,
                  color: Colors.black87,
                  margin: EdgeInsets.only(
                      top: _JianpuMeasure.labelHeight * scale),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _JianpuMeasure extends StatelessWidget {
  static const double labelHeight = 10;

  final Measure measure;
  final bool isSelected;
  final bool isFlagged;
  final ValueNotifier<int?> Function(int) notifierForMeasure;
  final String? sectionLabel;
  final VoidCallback? onTap;
  final double scale;

  const _JianpuMeasure({
    required this.measure,
    required this.isSelected,
    required this.notifierForMeasure,
    required this.scale,
    this.isFlagged = false,
    this.sectionLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final naturalWidth = NotationLayout.measureWidth(measure);
    final scaledWidth = naturalWidth * scale;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
        width: scaledWidth,
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primaryContainer.withAlpha(180)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: labelHeight * scale,
              child: sectionLabel != null
                  ? Text(
                      sectionLabel!,
                      style: TextStyle(
                        fontSize: 9 * scale,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                    )
                  : null,
            ),
            SizedBox(
              height: NotationLayout.rowHeight * scale,
              child: ValueListenableBuilder<int?>(
                valueListenable: notifierForMeasure(measure.number),
                builder: (_, noteIndex, _) => CustomPaint(
                  size: Size(scaledWidth, NotationLayout.rowHeight * scale),
                  painter: _JianpuMeasurePainter(
                    notes: measure.notes,
                    activeNoteIndex: noteIndex,
                    scale: scale,
                  ),
                ),
              ),
            ),
          ],
        ),
          ),
          if (isFlagged)
            Positioned(
              top: labelHeight * scale,
              right: 1,
              child: const Icon(Icons.warning_amber_rounded,
                  size: 12, color: Colors.deepOrange),
            ),
        ],
      ),
    );
  }
}

class _JianpuMeasurePainter extends CustomPainter {
  final List<NoteEvent> notes;
  final int? activeNoteIndex;
  final double scale;

  _JianpuMeasurePainter(
      {required this.notes, this.activeNoteIndex, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale, scale);

    final idx = activeNoteIndex;
    if (idx != null && idx < notes.length) {
      final note = notes[idx];
      if (!note.isRest && (_isLongerThanQuarter(note) || idx == 0)) {
        double x = 0;
        for (int i = 0; i < idx; i++) x += NotationLayout.noteWidth(notes[i]);
        canvas.drawRect(
          Rect.fromLTWH(x, 0, NotationLayout.noteWidth(note),
              NotationLayout.rowHeight),
          Paint()..color = Colors.amber.withAlpha(140),
        );
      }
    }

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
        _drawText(canvas, textPainter, '#', centerX - 10, baseY - 8,
            fontSize: 10);
      }

      _drawText(canvas, textPainter, '$num', centerX, baseY, fontSize: 18);

      if (octaveDots > 0) {
        for (int d = 0; d < octaveDots; d++) {
          canvas.drawCircle(Offset(centerX, baseY - 16 - d * 6), 2,
              Paint()..color = Colors.black);
        }
      } else if (octaveDots < 0) {
        for (int d = 0; d < -octaveDots; d++) {
          canvas.drawCircle(Offset(centerX, baseY + 14 + d * 6), 2,
              Paint()..color = Colors.black);
        }
      }

      final underlineCount = _underlineCount(note.noteValue);
      for (int u = 0; u < underlineCount; u++) {
        final y = baseY + 12 + u * 4;
        canvas.drawLine(
            Offset(x + 4, y), Offset(x + nw - 4, y), linePaint);
      }

      if (note.dotted) {
        canvas.drawCircle(Offset(centerX + 10, baseY + 2), 2,
            Paint()..color = Colors.black);
      }

      final dashCount = _dashCount(note.noteValue, note.dotted);
      for (int d = 1; d <= dashCount; d++) {
        final dashCX =
            x + d * NotationLayout.cellWidth + NotationLayout.cellWidth / 2;
        _drawText(canvas, textPainter, '—', dashCX, baseY, fontSize: 18);
      }

      x += nw;
    }

    canvas.restore();
  }

  int _underlineCount(NoteValue v) {
    switch (v) {
      case NoteValue.eighth:
        return 1;
      case NoteValue.sixteenth:
        return 2;
      default:
        return 0;
    }
  }

  int _dashCount(NoteValue v, bool dotted) {
    switch (v) {
      case NoteValue.whole:
        return 3;
      case NoteValue.half:
        return dotted ? 2 : 1;
      default:
        return 0;
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

  static bool _isLongerThanQuarter(NoteEvent note) {
    if (note.noteValue == NoteValue.whole ||
        note.noteValue == NoteValue.half) return true;
    if (note.noteValue == NoteValue.quarter && note.dotted) return true;
    return false;
  }

  @override
  bool shouldRepaint(covariant _JianpuMeasurePainter old) =>
      old.notes != notes ||
      old.activeNoteIndex != activeNoteIndex ||
      old.scale != scale;
}

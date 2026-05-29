import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece_layout.dart';
import 'notation_layout_engine.dart';

class FingeringView extends StatefulWidget {
  final PieceLayout layout;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final bool combined;
  final ValueNotifier<int?> Function(int measureNumber) notifierForMeasure;
  final ValueListenable<int?>? currentMeasureNotifier;

  const FingeringView({
    super.key,
    required this.layout,
    required this.selectedMeasures,
    required this.sectionLabels,
    required this.notifierForMeasure,
    this.onMeasureTap,
    this.combined = false,
    this.currentMeasureNotifier,
  });

  @override
  State<FingeringView> createState() => _FingeringViewState();
}

class _FingeringViewState extends State<FingeringView> {
  final _scrollController = ScrollController();
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    widget.currentMeasureNotifier?.addListener(_onMeasureChanged);
  }

  @override
  void didUpdateWidget(FingeringView old) {
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

    const labelH = 16.0;
    final noteAreaH =
        widget.combined ? NotationLayout.rowHeight + 20.0 : NotationLayout.rowHeight;
    // Symmetric vertical padding EdgeInsets.symmetric(vertical: 4) → 8pt total
    const rowPad = 8.0;
    final rowH = (labelH + noteAreaH) * _scale + rowPad;

    final rowTop = rowIndex * rowH;
    final rowBottom = rowTop + rowH;

    final pos = _scrollController.position;
    final viewTop = pos.pixels;
    final viewBottom = pos.pixels + pos.viewportDimension;

    if (rowBottom > viewBottom) {
      _scrollController.animateTo(
        (rowBottom - pos.viewportDimension + 8).clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else if (rowTop < viewTop) {
      _scrollController.animateTo(
        (rowTop - 8).clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
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
          children: widget.layout.rows.map((row) {
            return _FingeringRow(
              measures: row,
              selectedMeasures: widget.selectedMeasures,
              sectionLabels: widget.sectionLabels,
              onMeasureTap: widget.onMeasureTap,
              combined: widget.combined,
              notifierForMeasure: widget.notifierForMeasure,
              scale: _scale,
            );
          }).toList(),
        ),
      );
    });
  }
}

class _FingeringRow extends StatelessWidget {
  final List<Measure> measures;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final bool combined;
  final ValueNotifier<int?> Function(int) notifierForMeasure;
  final double scale;

  const _FingeringRow({
    required this.measures,
    required this.selectedMeasures,
    required this.sectionLabels,
    required this.combined,
    required this.notifierForMeasure,
    required this.scale,
    this.onMeasureTap,
  });

  @override
  Widget build(BuildContext context) {
    final rowH = combined
        ? NotationLayout.rowHeight + 20.0
        : NotationLayout.rowHeight;
    const labelH = 16.0;
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
                notifierForMeasure: notifierForMeasure,
                sectionLabel: sectionLabels[measures[i].number],
                onTap: () => onMeasureTap?.call(measures[i].number),
                combined: combined,
                rowHeight: rowH,
                scale: scale,
              ),
              if (i < measures.length - 1)
                Container(
                  width: NotationLayout.barlineWidth * scale,
                  height: (rowH + labelH) * scale,
                  color: Colors.black87,
                  margin: EdgeInsets.only(top: labelH * scale),
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
  final ValueNotifier<int?> Function(int) notifierForMeasure;
  final String? sectionLabel;
  final VoidCallback? onTap;
  final bool combined;
  final double rowHeight;
  final double scale;

  const _FingeringMeasure({
    required this.measure,
    required this.isSelected,
    required this.notifierForMeasure,
    this.sectionLabel,
    this.onTap,
    required this.combined,
    required this.rowHeight,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final naturalWidth = NotationLayout.measureWidth(measure);
    final scaledWidth = naturalWidth * scale;
    return GestureDetector(
      onTap: onTap,
      child: Container(
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
              height: 16 * scale,
              child: sectionLabel != null
                  ? Text(
                      sectionLabel!,
                      style: TextStyle(
                        fontSize: 11 * scale,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                    )
                  : null,
            ),
            SizedBox(
              height: rowHeight * scale,
              child: ValueListenableBuilder<int?>(
                valueListenable: notifierForMeasure(measure.number),
                builder: (_, noteIndex, _) => CustomPaint(
                  size: Size(scaledWidth, rowHeight * scale),
                  painter: _FingeringMeasurePainter(
                    notes: measure.notes,
                    combined: combined,
                    activeNoteIndex: noteIndex,
                    scale: scale,
                  ),
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
  final int? activeNoteIndex;
  final double scale;

  _FingeringMeasurePainter(
      {required this.notes,
      required this.combined,
      this.activeNoteIndex,
      required this.scale});

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
          Rect.fromLTWH(
              x, 0, NotationLayout.noteWidth(note), NotationLayout.rowHeight),
          Paint()..color = Colors.amber.withAlpha(140),
        );
      }
    }

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
        _drawFingeringLabel(
            canvas, tp, fs, fn, centerX, combined ? baseY + 10 : baseY);
      }
      x += nw;
    }

    canvas.restore();
  }

  void _drawFingeringLabel(Canvas canvas, TextPainter tp, String str,
      String finger, double cx, double cy) {
    _drawText(canvas, tp, '$str$finger', cx, cy, fontSize: 15);
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
  bool shouldRepaint(covariant _FingeringMeasurePainter old) =>
      old.notes != notes ||
      old.combined != combined ||
      old.activeNoteIndex != activeNoteIndex ||
      old.scale != scale;
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/piece_layout.dart';
import 'notation_layout_engine.dart';
import 'notation_run_scroll.dart';
import 'section_run_header.dart';

class FingeringView extends StatefulWidget {
  final PieceLayout layout;
  final Set<int> selectedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final bool combined;
  final ValueNotifier<int?> Function(int measureNumber) notifierForMeasure;
  final ValueListenable<int?>? currentMeasureNotifier;

  /// Per-section-label tint color for the inline section bands; empty disables
  /// section headers (falls back to plain rows).
  final Map<String, Color> sectionColors;

  /// Minimap scroll-to-section request (run index + a sequence so identical
  /// requests still fire); null until the minimap is tapped.
  final ({int run, int seq})? navTarget;

  /// Called with the top-most visible section-run index as the user scrolls.
  final ValueChanged<int>? onVisibleRunChanged;

  /// Measures whose beat total doesn't match the time signature (OMR errors);
  /// flagged measures get a small warning glyph.
  final Set<int> flaggedMeasures;

  const FingeringView({
    super.key,
    required this.layout,
    required this.selectedMeasures,
    required this.sectionLabels,
    required this.notifierForMeasure,
    this.onMeasureTap,
    this.combined = false,
    this.currentMeasureNotifier,
    this.sectionColors = const {},
    this.navTarget,
    this.onVisibleRunChanged,
    this.flaggedMeasures = const {},
  });

  @override
  State<FingeringView> createState() => _FingeringViewState();
}

class _FingeringViewState extends State<FingeringView> with NotationRunScroll {
  final _scrollController = ScrollController();
  double _scale = 1.0;

  @override
  ScrollController get scrollController => _scrollController;
  @override
  PieceLayout get layout => widget.layout;
  @override
  ValueChanged<int>? get onVisibleRunChanged => widget.onVisibleRunChanged;

  @override
  void initState() {
    super.initState();
    widget.currentMeasureNotifier?.addListener(_onMeasureChanged);
    _scrollController.addListener(reportVisibleRun);
    WidgetsBinding.instance.addPostFrameCallback((_) => reportVisibleRun());
  }

  @override
  void didUpdateWidget(FingeringView old) {
    super.didUpdateWidget(old);
    if (old.currentMeasureNotifier != widget.currentMeasureNotifier) {
      old.currentMeasureNotifier?.removeListener(_onMeasureChanged);
      widget.currentMeasureNotifier?.addListener(_onMeasureChanged);
    }
    if (widget.navTarget != null && widget.navTarget != old.navTarget) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => scrollToRun(widget.navTarget!.run));
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
    WidgetsBinding.instance.addPostFrameCallback((_) => scrollToMeasure(m));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final availableWidth = constraints.maxWidth;
      final maxRowW = widget.layout.rows.isEmpty
          ? 1.0
          : widget.layout.rows.map(NotationLayout.rowWidth).reduce(math.max);
      _scale = (availableWidth / maxRowW).clamp(0.0, 1.0);

      Widget rowWidget(int ri) => KeyedSubtree(
            key: rowKey(ri),
            child: _FingeringRow(
              measures: widget.layout.rows[ri],
              selectedMeasures: widget.selectedMeasures,
              flaggedMeasures: widget.flaggedMeasures,
              sectionLabels: widget.sectionLabels,
              onMeasureTap: widget.onMeasureTap,
              combined: widget.combined,
              notifierForMeasure: widget.notifierForMeasure,
              scale: _scale,
            ),
          );

      final runs = widget.layout.runs;
      final children = <Widget>[
        if (runs.isEmpty)
          for (var ri = 0; ri < widget.layout.rows.length; ri++) rowWidget(ri)
        else
          for (var i = 0; i < runs.length; i++)
            SectionRunBlock(
              title: runs[i].title,
              color: widget.sectionColors[runs[i].label],
              headerKey: runHeaderKey(i),
              children: [
                for (var ri = runs[i].rowStart; ri < runs[i].rowEnd; ri++)
                  rowWidget(ri),
              ],
            ),
      ];

      return SingleChildScrollView(
        controller: _scrollController,
        child: Column(children: children),
      );
    });
  }
}

class _FingeringRow extends StatelessWidget {
  final List<Measure> measures;
  final Set<int> selectedMeasures;
  final Set<int> flaggedMeasures;
  final Map<int, String> sectionLabels;
  final ValueChanged<int>? onMeasureTap;
  final bool combined;
  final ValueNotifier<int?> Function(int) notifierForMeasure;
  final double scale;

  const _FingeringRow({
    required this.measures,
    required this.selectedMeasures,
    required this.flaggedMeasures,
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
                isFlagged: flaggedMeasures.contains(measures[i].number),
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
  final bool isFlagged;
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
    this.isFlagged = false,
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
          if (isFlagged)
            const Positioned(
              top: 16,
              right: 1,
              child: Icon(Icons.warning_amber_rounded,
                  size: 12, color: Colors.deepOrange),
            ),
          // Repeat barlines, centered vertically on the note row so they read as
          // a `|:` (start) / `:|` (end) bracket without clashing with the
          // top-right flagged-measure warning.
          if (measure.repeatStart)
            Positioned(
              left: 1,
              top: 16 * scale,
              bottom: 0,
              child: Center(child: _repeatGlyph('|:', scale)),
            ),
          if (measure.repeatEnd)
            Positioned(
              right: 1,
              top: 16 * scale,
              bottom: 0,
              child: Center(child: _repeatGlyph(':|', scale)),
            ),
        ],
      ),
    );
  }

  static Widget _repeatGlyph(String glyph, double scale) => Text(
        glyph,
        style: TextStyle(
          fontSize: 16 * scale,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      );
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

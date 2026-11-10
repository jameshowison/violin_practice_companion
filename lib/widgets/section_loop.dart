import 'package:flutter/material.dart';

import '../models/section_run_groups.dart';
import '../services/midi_generator.dart'; // HighlightEvent
import '../services/providers.dart'; // MeasureSelection
import '../models/section_run.dart';

/// The repeat loop drawn over a folded group in the section picker
/// ([RunGroup.isLoop]): a line that leaves the group's end, runs back along it
/// and arrows down (or, on the vertical rail, across) into its start — "play
/// these again" — with one dot per pass set into the line, filled as the
/// passes are played.
///
/// [Axis.horizontal] is the phone chip row: drawn in a strip ABOVE the chips,
/// end on the right, arrowhead pointing down at the first chip.
/// [Axis.vertical] is the tablet rail: drawn in a gutter to the LEFT of the
/// emblems, end at the bottom, arrowhead pointing right at the first emblem.
class SectionLoopPainter extends CustomPainter {
  final Axis axis;

  /// The line's colour: dark while the loop is current, grey otherwise.
  final Color color;

  /// A filled dot's colour, which stays dark once that pass has been played.
  final Color dotColor;
  final int passes;
  final int filled;

  /// Trims the far end, so the loop stops over the last chip rather than its
  /// trailing margin.
  final double endInset;

  const SectionLoopPainter({
    required this.axis,
    required this.color,
    required this.dotColor,
    required this.passes,
    required this.filled,
    this.endInset = 0,
  });

  static const _dot = 4.2; // diameter, outline included
  static const _dotGap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color;
    const r = 3.0; // corner radius
    const head = 3.0; // arrowhead half-width
    final dotsLen = passes * _dot + (passes - 1) * _dotGap;
    final gap = dotsLen + 3;

    void dots(Offset first, Offset step) {
      final ring = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1;
      final solid = Paint()..color = dotColor;
      for (var i = 0; i < passes; i++) {
        final c = first + step * i.toDouble();
        if (i < filled) {
          canvas.drawCircle(c, _dot / 2, solid);
        } else {
          canvas.drawCircle(c, _dot / 2 - 0.55, ring);
        }
      }
    }

    if (axis == Axis.horizontal) {
      const line = 3.0; // the run-back line, level with the dots
      // Close to the chip edges, so a one-chip loop keeps some visible line.
      final left = 4.0, right = size.width - endInset - 4;
      final bottom = size.height - 1.5; // a hair above the chip
      final mid = (left + right) / 2;
      final path = Path()
        ..moveTo(right, bottom)
        ..lineTo(right, line + r)
        ..quadraticBezierTo(right, line, right - r, line)
        ..lineTo(mid + gap / 2, line)
        ..moveTo(mid - gap / 2, line)
        ..lineTo(left + r, line)
        ..quadraticBezierTo(left, line, left, line + r)
        ..lineTo(left, bottom - head);
      canvas.drawPath(path, stroke);
      canvas.drawPath(
          Path()
            ..moveTo(left - head, bottom - head - 0.5)
            ..lineTo(left + head, bottom - head - 0.5)
            ..lineTo(left, bottom + 0.5)
            ..close(),
          fill);
      dots(Offset(mid - dotsLen / 2 + _dot / 2, line),
          const Offset(_dot + _dotGap, 0));
    } else {
      const line = 5.0; // the run-back line's x
      final right = size.width - 1.5; // a hair short of the emblem
      final top = 6.0, bottom = size.height - endInset - 6;
      final mid = (top + bottom) / 2;
      final path = Path()
        ..moveTo(right, bottom)
        ..lineTo(line + r, bottom)
        ..quadraticBezierTo(line, bottom, line, bottom - r)
        ..lineTo(line, mid + gap / 2)
        ..moveTo(line, mid - gap / 2)
        ..lineTo(line, top + r)
        ..quadraticBezierTo(line, top, line + r, top)
        ..lineTo(right - head, top);
      canvas.drawPath(path, stroke);
      canvas.drawPath(
          Path()
            ..moveTo(right - head - 0.5, top - head)
            ..lineTo(right - head - 0.5, top + head)
            ..lineTo(right + 0.5, top)
            ..close(),
          fill);
      dots(Offset(line, mid - dotsLen / 2 + _dot / 2),
          const Offset(0, _dot + _dotGap));
    }
  }

  @override
  bool shouldRepaint(SectionLoopPainter old) =>
      old.axis != axis ||
      old.color != color ||
      old.dotColor != dotColor ||
      old.passes != passes ||
      old.filled != filled ||
      old.endInset != endInset;
}

/// How a group in the section picker should be drawn right now — shared by
/// the phone chip row and the tablet rail so both read the same.
class RunGroupState {
  /// Every chip of the group lit: the whole group is the selection (its loop
  /// or its D.C. label was tapped), and nothing is playing.
  final bool wholeSelected;

  /// The loop line / D.C. label drawn dark.
  final bool lit;

  /// Pass dots to fill: up to the pass being played, all of them once the
  /// group has been played through, none otherwise.
  final int filled;

  const RunGroupState(
      {required this.wholeSelected, required this.lit, required this.filled});

  factory RunGroupState.of(RunGroup g, List<SectionRun> runs, int? current,
      HighlightEvent? play, MeasureSelection? selection) {
    final whole = MeasureSelection.ofRuns(runs[g.firstRun], runs[g.lastRun]);
    final wholeSelected =
        (g.isLoop || g.isJump) && play == null && selection == whole;
    final pass = wholeSelected ? null : g.passOf(current);
    final done = play != null && current != null && current > g.lastRun;
    return RunGroupState(
      wholeSelected: wholeSelected,
      lit: pass != null || selection == whole,
      filled: pass != null ? pass + 1 : (done ? g.passes : 0),
    );
  }
}

/// The D.C./D.S. instruction over (or, on the rail, above) the stretch played
/// after the jump.
TextStyle sectionJumpLabelStyle(Color color, {double fontSize = 9.5}) =>
    TextStyle(
      fontSize: fontSize,
      height: 1.0,
      fontWeight: FontWeight.w600,
      fontStyle: FontStyle.italic,
      color: color,
    );

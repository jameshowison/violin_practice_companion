import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/recorder_fingering.dart';

/// A recorder or a flute drawn upright, its holes showing one
/// [HoleFingering]: the wind equivalent of `ChordDiagram`.
///
/// The recorder: the thumb hole is at the back, drawn to the left of hole 1;
/// holes 1–3 are the left hand, a gap, then 4–7 the right, with 6 and 7 each
/// a double hole (a larger and a smaller one side by side). The flute (no
/// thumb hole): its embouchure hole at the top, then holes 1–3 and 4–6 a
/// place lower, drawn upright as an Irish flute or whistle chart draws them.
/// Closed is filled, open a ring, half is half filled (the pinched thumb, a
/// flute's half-hole) or the larger of a pair filled.
///
/// With [changedFrom], the holes that differ from it are ringed: a solid ring
/// in the theme's primary colour for a hole going down (or half), a dashed
/// grey ring for one coming up. Sizes are fractions of [height], so the same
/// drawing serves the panel's big diagram and the "Next" thumbnail.
class HoleDiagram extends StatelessWidget {
  final HoleFingering fingering;
  final HoleFingering? changedFrom;
  final bool showNumbers;
  final double height;

  const HoleDiagram({
    super.key,
    required this.fingering,
    this.changedFrom,
    this.showNumbers = false,
    required this.height,
  });

  /// Width over height of the drawing.
  static const double aspect = HoleDiagramPainter.viewWidth /
      HoleDiagramPainter.viewHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Fingering ${fingering.pattern}',
      child: CustomPaint(
        size: Size(height * aspect, height),
        painter: HoleDiagramPainter(
          fingering: fingering,
          changedFrom: changedFrom,
          showNumbers: showNumbers,
          ink: scheme.onSurface,
          paper: scheme.surface,
          body: scheme.surfaceContainerHighest,
          outline: scheme.outline,
          added: scheme.primary,
          lifted: scheme.outline,
        ),
      ),
    );
  }
}

class HoleDiagramPainter extends CustomPainter {
  HoleDiagramPainter({
    required this.fingering,
    required this.changedFrom,
    required this.showNumbers,
    required this.ink,
    required this.paper,
    required this.body,
    required this.outline,
    required this.added,
    required this.lifted,
  });

  final HoleFingering fingering;
  final HoleFingering? changedFrom;
  final bool showNumbers;
  final Color ink, paper, body, outline, added, lifted;

  // The drawing's own units: one unit is the spacing of two holes.
  static const double viewLeft = -1.8, viewTop = 0.25;
  static const double viewWidth = 3.1, viewHeight = 8.0;

  /// Hole centres in view units, 0 = the thumb.
  static const List<Offset> centres = [
    Offset(-1.2, 1.0),
    Offset(0, 1.0),
    Offset(0, 2.0),
    Offset(0, 3.0),
    Offset(0, 4.5),
    Offset(0, 5.5),
    Offset(0, 6.5),
    Offset(0, 7.5),
  ];

  static const double _r = 0.36, _ring = 0.56;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.height / viewHeight;
    canvas.save();
    canvas.scale(k);
    canvas.translate(-viewLeft, -viewTop);

    final stroke = 0.09;
    // The body.
    final bodyRect = RRect.fromRectAndRadius(
        const Rect.fromLTRB(-0.62, 0.42, 0.62, 8.05), const Radius.circular(0.62));
    canvas.drawRRect(bodyRect, Paint()..color = body);
    canvas.drawRRect(
        bodyRect,
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 0.6);

    final recorder = fingering.hasThumb;
    if (!recorder) {
      // The flute's embouchure hole: blown across, never covered.
      canvas.drawOval(
          Rect.fromCenter(
              center: const Offset(0, 1.0), width: 0.62, height: 0.4),
          Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke);
    }
    final changed = changedHoles(changedFrom, fingering);
    for (var i = recorder ? 0 : 1; i < fingering.holeCount; i++) {
      // The flute's holes sit a place lower, under its embouchure hole.
      final c = centres[recorder ? i : i + 1];
      final state = fingering.hole(i);
      if (recorder && i >= 6) {
        _doubleHole(canvas, c, state, stroke);
      } else {
        _hole(canvas, c, _r, state, stroke);
      }
      if (changed.contains(i)) {
        final goingUp = state == HoleState.open;
        final ring = Paint()
          ..color = goingUp ? lifted : added
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.6;
        if (goingUp) {
          _dashedCircle(canvas, c, _ring, ring);
        } else {
          canvas.drawCircle(c, _ring, ring);
        }
      }
    }
    canvas.restore();
    // The numbers in screen units: text laid out at a fraction of a point
    // inside the scaled canvas is placed unreliably.
    if (showNumbers) {
      final shift = fingering.hasThumb ? 0 : 1;
      for (var i = 1; i < fingering.holeCount; i++) {
        final tp = TextPainter(
          text: TextSpan(
              text: '$i',
              style: TextStyle(color: outline, fontSize: 0.42 * k, height: 1)),
          textDirection: TextDirection.ltr,
        )..layout();
        final c = (centres[i + shift] +
                const Offset(-viewLeft + 0.68, -viewTop)) *
            k;
        tp.paint(canvas, c - Offset(0, tp.height / 2));
      }
    }
  }

  void _hole(Canvas canvas, Offset c, double r, HoleState state, double stroke) {
    final rim = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(c, r, Paint()..color = paper);
    switch (state) {
      case HoleState.closed:
        canvas.drawCircle(c, r, Paint()..color = ink);
      case HoleState.half:
        // The left half filled: the thumbnail pinches the hole.
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), math.pi / 2,
            math.pi, true, Paint()..color = ink);
      case HoleState.open:
        break;
    }
    canvas.drawCircle(c, r, rim);
  }

  /// A double hole: the larger to the left, the smaller to the right. Half
  /// covers the larger alone.
  void _doubleHole(Canvas canvas, Offset c, HoleState state, double stroke) {
    final big = state == HoleState.open ? HoleState.open : HoleState.closed;
    final small = state == HoleState.closed ? HoleState.closed : HoleState.open;
    _hole(canvas, c + const Offset(-0.14, 0), 0.25, big, stroke);
    _hole(canvas, c + const Offset(0.27, 0), 0.15, small, stroke);
  }

  void _dashedCircle(Canvas canvas, Offset c, double r, Paint paint) {
    const dashes = 12;
    const sweep = 2 * math.pi / dashes;
    final rect = Rect.fromCircle(center: c, radius: r);
    for (var d = 0; d < dashes; d++) {
      canvas.drawArc(rect, d * sweep, sweep * 0.55, false, paint);
    }
  }

  @override
  bool shouldRepaint(HoleDiagramPainter old) =>
      old.fingering != fingering ||
      old.changedFrom != changedFrom ||
      old.showNumbers != showNumbers ||
      old.ink != ink ||
      old.paper != paper ||
      old.body != body ||
      old.added != added;
}

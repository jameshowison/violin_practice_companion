import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../splash/stringlings_art.g.dart';

/// The tuner's AppBar icon: a happy stringling hanging by its arms from the
/// yellow E-string rule, feet dangling over the red A-string rule. A
/// two-string, icon-sized cousin of the app icon
/// (scripts/app_icon/stringlings_icon.mjs) and the tuner's climber, wearing
/// the climber's in-tune face: eyes shut in happy arcs and an open grin.
///
/// Tuned by eye on the "Tuner Button Stringling" slider page, 2026-11-13.
///
/// 28 pt by default, a little over a Material icon, so the smile reads in
/// the AppBar; [size] overrides it.
class StringlingTunerIcon extends StatelessWidget {
  const StringlingTunerIcon({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: const CustomPaint(painter: _TunerIconPainter()),
    );
  }
}

const _ink = kStringlingsPupil;
const _white = kStringlingsEyeWhite;
const _ruleA = Color(0xFFC62828);
const _ruleE = Color(0xFFC9961C); // the icon's E, darkened for a light ground

class _TunerIconPainter extends CustomPainter {
  const _TunerIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn in a 24×24 box, like a Material icon.
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(k);

    const ruleH = 2.6;
    const eY = 3.6, aY = 19.6; // rule centres
    const eTop = eY - ruleH / 2;
    const cx = 12.0, rx = 6.8, ry = rx * 0.93;
    const cy = eY + ruleH / 2 + ry * 1.05; // hangs below the E rule
    const hands = [cx - rx * 0.8, cx + rx * 0.8];

    void rule(double y, Color c) => canvas.drawRRect(
        RRect.fromLTRBR(1, y - ruleH / 2, 23, y + ruleH / 2, const Radius.circular(ruleH / 2)),
        Paint()..color = c);

    rule(eY, _ruleE);
    rule(aY, _ruleA);

    final ink = Paint()..color = _ink;

    // Arms up to the E rule, behind the body, as the climber draws them.
    final arm = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5;
    for (var i = 0; i < 2; i++) {
      final side = i == 0 ? -1.0 : 1.0, hx = hands[i];
      final sx = cx + side * rx * 0.8, sy = cy - ry * 0.05;
      canvas.drawPath(
          Path()
            ..moveTo(sx, sy)
            ..quadraticBezierTo((sx + hx) / 2 + side * 0.6, (sy + eY) / 2, hx, eY),
          arm);
    }

    // Dangling feet.
    for (final s in [-1.0, 1.0]) {
      canvas.drawOval(
          Rect.fromCenter(
              center: Offset(cx + s * rx * 0.36, cy + ry * 0.92), width: rx * 0.44, height: ry * 0.3),
          ink);
    }

    // Body.
    canvas.drawOval(
        Rect.fromCenter(center: const Offset(cx, cy), width: 2 * rx, height: 2 * ry), ink);

    // Happy eyes: upward arcs.
    const ey = cy - ry * 0.34, edx = rx * 0.38, ew = rx * 0.2;
    final wStroke = Paint()
      ..color = _white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.3;
    for (final side in [-1.0, 1.0]) {
      canvas.drawArc(
          Rect.fromCircle(center: Offset(cx + side * edx, ey + ew * 0.45), radius: ew),
          math.pi * 1.12, math.pi * 0.76, false, wStroke);
    }

    // Open grin.
    const my = cy + ry * 0.08, mw = rx * 0.42, mh = ry * 0.2;
    canvas.drawPath(
        Path()
          ..moveTo(cx - mw, my - mh * 0.2)
          ..quadraticBezierTo(cx, my + mh * 2.5, cx + mw, my - mh * 0.2)
          ..close(),
        Paint()..color = _white);

    // Fingers curled over the E rule, two a hand at this size.
    const fw = 1.3;
    for (final hx in hands) {
      for (final o in [-0.7, 0.7]) {
        canvas.drawRRect(
            RRect.fromLTRBR(hx + o * fw - fw / 2, eTop - fw * 0.45, hx + o * fw + fw / 2,
                eTop + ruleH * 0.8, const Radius.circular(fw / 2)),
            ink);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TunerIconPainter old) => false;
}

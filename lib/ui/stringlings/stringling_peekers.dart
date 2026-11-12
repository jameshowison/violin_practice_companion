import 'package:flutter/material.dart';

import '../splash/stringlings_art.g.dart';

/// The icon's two stringlings peeking over their A- and E-string fingering
/// rules, without the staff and notes: a small mascot for the Playful piece
/// screen's title. Blinks every few seconds (big one, then the little one a
/// beat later, as on the splash); still under reduced motion.
///
/// Drawn from the same geometry as scripts/app_icon/stringlings_icon.mjs
/// (`peeker()`), in the icon's 1024 space, cropped to the two figures. If the
/// icon's figures move there, move them here.
class StringlingPeekers extends StatefulWidget {
  const StringlingPeekers({super.key, required this.height});

  final double height;

  /// Width over height of the cropped figures.
  static const aspect = _cropW / _cropH;

  @override
  State<StringlingPeekers> createState() => _StringlingPeekersState();
}

// The crop of the 1024 icon that holds both figures, rules and fingers.
const _cropX = 120.0, _cropY = 195.0, _cropW = 800.0, _cropH = 230.0;

// One blink cycle, in seconds: the eyes stay open most of it.
const _period = 6.5;
const _bigAt = 5.0, _littleAt = 5.09, _blinkLength = 0.17;

class _StringlingPeekersState extends State<StringlingPeekers>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_period * 1000).round()),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _clock.stop();
      _clock.value = 0;
    } else if (!_clock.isAnimating) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  static double _openness(double t, double start) {
    final d = (t - start) / _blinkLength;
    if (d <= 0 || d >= 1) return 1;
    return Curves.easeInOut.transform((2 * d - 1).abs());
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: widget.height * StringlingPeekers.aspect,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _clock,
          builder: (context, _) {
            final t = _clock.value * _period;
            return CustomPaint(
              painter: _PeekersPainter(
                big: _openness(t, _bigAt),
                little: _openness(t, _littleAt),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One stringling: where its head sits on its rule, and the rule's extent.
class _Peeker {
  const _Peeker(this.cx, this.ruleY, this.h, this.rx, this.ry, this.rule,
      this.x1, this.x2);
  final double cx, ruleY, h, rx, ry, x1, x2;
  final Color rule;
}

// As called in the .mjs: big on the A-string rule, little on the E.
const _big = _Peeker(370, 400, 40, 140, 122, Color(0xFFC62828), 130, 610);
const _little = _Peeker(795, 318, 34, 92, 80, Color(0xFFC9961C), 680, 910);

class _PeekersPainter extends CustomPainter {
  _PeekersPainter({required this.big, required this.little});

  final double big, little;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.height / _cropH;
    canvas.save();
    canvas.scale(k);
    canvas.translate(-_cropX, -_cropY);
    _draw(canvas, _big, big);
    _draw(canvas, _little, little);
    canvas.restore();
  }

  void _draw(Canvas canvas, _Peeker p, double open) {
    final ink = Paint()..color = kStringlingsPupil;
    final top = p.ruleY - p.h / 2;
    final cy = p.ruleY - p.ry * 0.45;

    // The head, cut off where the rule hides the rest of it.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, -100, 1024, top + 1));
    canvas.drawOval(
        Rect.fromCenter(center: Offset(p.cx, cy), width: 2 * p.rx, height: 2 * p.ry),
        ink);
    final ey = cy - p.ry * 0.22, dx = p.rx * 0.34;
    final ew = p.rx * 0.22, eh = p.ry * 0.3, pr = p.rx * 0.12;
    if (open >= 0.04) {
      final white = Paint()..color = kStringlingsEyeWhite;
      for (final sx in [p.cx - dx, p.cx + dx]) {
        final eye = Rect.fromCenter(
            center: Offset(sx, ey), width: 2 * ew, height: 2 * eh * open);
        canvas.save();
        canvas.clipPath(Path()..addOval(eye));
        canvas.drawOval(eye, white);
        canvas.drawCircle(Offset(sx + p.rx * 0.03, ey + eh * 0.42), pr, ink);
        canvas.restore();
      }
    }
    canvas.restore();

    // The rule, then the fingers curled over it.
    canvas.drawRRect(
        RRect.fromLTRBR(p.x1, top, p.x2, top + p.h, Radius.circular(p.h / 2)),
        Paint()..color = p.rule);
    final fw = (p.rx * 0.12).clamp(14.0, double.infinity);
    for (final hx in [p.cx - p.rx * 0.78, p.cx + p.rx * 0.78]) {
      for (final j in [-1, 0, 1]) {
        final x = hx + j * fw * 1.15 - fw / 2, y = top - fw * 0.55;
        canvas.drawRRect(
            RRect.fromLTRBR(x, y, x + fw, y + p.h * 0.75 + fw * 0.55,
                Radius.circular(fw / 2)),
            ink);
      }
    }
  }

  @override
  bool shouldRepaint(_PeekersPainter old) =>
      old.big != big || old.little != little;
}

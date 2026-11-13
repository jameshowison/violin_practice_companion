import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../splash/stringlings_art.g.dart';

/// One string's rung on the ladder.
class ClimberRung {
  const ClimberRung({required this.letter, required this.caption, required this.color});

  /// `G`, `D`, `A`, `E`.
  final String letter;

  /// Small text over the rung, e.g. `G3 · 195.56 Hz`.
  final String caption;
  final Color color;
}

/// The tuner's picture: the strings' fingering rules stacked as a ladder,
/// lowest at the bottom, and a stringling doing a chin-up on the string being
/// tuned. Flat, it hangs below its rule; sharp, it is shoved up over it; in
/// tune, it rests on the rule and grins. Its face goes from joy through worry
/// and wincing to agony as the pitch drifts, on the scale in
/// [StringlingFace.pain] (cues people read as pain: brows that lift and then
/// knot, eyes that squeeze shut, a mouth that wobbles and then grits).
///
/// Changing [target] makes it climb there, one rung at a time, hand over
/// hand. [cents] null is idle: resting, blinking, listening.
///
/// With [fineTuners], a turning arrow just above the string's rule shows
/// which way to turn its fine tuner: clockwise raises the pitch, so flat
/// shows clockwise and sharp anti-clockwise. Hidden when in tune, idle or
/// climbing.
///
/// Ported from the approved design prototype (the "Stringling Tuner"
/// artifact). The body is the icon's stringling (scripts/app_icon/
/// stringlings_icon.mjs): same ink, eyes and curled fingers.
class StringlingClimber extends StatefulWidget {
  const StringlingClimber({
    super.key,
    required this.rungs,
    required this.target,
    required this.cents,
    this.doubled = false,
    this.fineTuners = false,
  });

  final List<ClimberRung> rungs;
  final int target;
  final double? cents;

  /// Draw each rung as a pair of thin rules, for a mandolin's courses.
  final bool doubled;

  /// Show the fine-tuner arrow (violin; a mandolin's tuners turn opposite
  /// ways on the two sides of the head, so one arrow would be wrong).
  final bool fineTuners;

  @override
  State<StringlingClimber> createState() => _StringlingClimberState();
}

class _Climb {
  _Climb(this.from, this.to, this.lead);
  final int from, to;
  final bool lead; // which hand reaches first
  double t = 0;
}

class _StringlingClimberState extends State<StringlingClimber>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _repaint = ValueNotifier<int>(0);
  Duration _last = Duration.zero;

  // Animation state, read by the painter.
  double t = 0; // seconds
  double shown = 0; // smoothed cents
  double held = 0; // seconds in tune
  int rung = 0;
  _Climb? climb;
  bool _flip = false;
  bool still = false;

  @override
  void initState() {
    super.initState();
    rung = widget.target;
    shown = widget.cents ?? 0;
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = math.min(0.05, (elapsed - _last).inMicroseconds / 1e6);
    _last = elapsed;
    t = elapsed.inMicroseconds / 1e6;

    final target = widget.cents ?? 0;
    shown += (target - shown) * (1 - math.exp(-dt * 9));

    final goal = widget.target.clamp(0, widget.rungs.length - 1);
    if (climb == null && rung != goal) {
      climb = _Climb(rung, rung + (goal > rung ? 1 : -1), _flip = !_flip);
    }
    final c = climb;
    if (c != null) {
      c.t += dt / (still ? 0.18 : 0.62);
      if (c.t >= 1) {
        rung = c.to;
        climb = null;
      }
    }
    if (climb == null && widget.cents != null && shown.abs() <= 3) {
      held += dt;
    } else {
      held = 0;
    }
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        painter: _ClimberPainter(this, _repaint),
        size: Size.infinite,
      ),
    );
  }
}

const _ink = kStringlingsPupil;
const _white = kStringlingsEyeWhite;
const _sweat = Color(0xFF7EC8F2);
const _blush = Color(0xFFF48FB1);
const _gold = Color(0xFFE8B21C);
const _inkSoft = Color(0xFF6A6180);
const _tuned = Color(0xFF2E7D32);

double _ease(double x) => x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x);

class _ClimberPainter extends CustomPainter {
  _ClimberPainter(this.s, Listenable repaint) : super(repaint: repaint);
  final _StringlingClimberState s;

  @override
  void paint(Canvas canvas, Size size) {
    final w = s.widget;
    final n = w.rungs.length;
    if (n == 0) return;
    final h = size.height, width = size.width;
    // Room above the top rule for a sharp stringling and the "Ready to tune?"
    // pill the screen lays over the card.
    final top = h * 0.28, bottom = h - h * 0.15;
    final gap = n > 1 ? (bottom - top) / (n - 1) : 0.0;
    double rungY(int i) => bottom - i * gap;
    final rx = math.max(20.0, math.min(48.0, math.min(width * 0.075, gap * 0.42)));
    final ry = rx * 0.87;
    final thick = math.max(8.0, rx * 0.26);
    const x1 = 58.0;
    final x2 = width - 18;
    final cx0 = x1 + (x2 - x1) * 0.55;

    final climbing = s.climb != null;
    final target = w.target.clamp(0, n - 1);
    final idle = w.cents == null;
    final inTune = !climbing && !idle && s.shown.abs() <= 3;

    // Rungs and their labels.
    for (var i = 0; i < n; i++) {
      final r = w.rungs[i];
      final active = i == target;
      final glow = active && inTune ? math.min(1.0, s.held * 2.5) : 0.0;
      _rung(canvas, x1, x2, rungY(i), thick, r.color.withValues(alpha: active ? 1 : 0.45),
          w.doubled, glow, r.color);
      _text(canvas, r.letter, Offset(28, rungY(i) + thick / 2),
          TextStyle(color: r.color, fontSize: math.min(26, gap * 0.36), fontWeight: FontWeight.w900),
          center: true);
      _text(canvas, r.caption, Offset(x1 + 4, rungY(i) - 5),
          const TextStyle(color: _inkSoft, fontSize: 10.5, fontFeatures: [FontFeature.tabularFigures()]),
          above: true);
    }

    // Pose.
    double handL, handR, anchor, p, dir, offset = 0;
    final c = s.climb;
    if (c != null) {
      final ya = rungY(c.from), yb = rungY(c.to);
      final lead = ya + (yb - ya) * _ease(c.t / 0.42);
      final trail = ya + (yb - ya) * _ease((c.t - 0.45) / 0.42);
      anchor = ya + (yb - ya) * _ease((c.t - 0.12) / 0.76);
      handL = c.lead ? lead : trail;
      handR = c.lead ? trail : lead;
      p = 0.3;
      dir = c.to > c.from ? -1 : 1; // looks where it is going
      offset = math.sin(c.t * math.pi) * ry * 0.25;
    } else {
      anchor = handL = handR = rungY(s.rung);
      if (idle) {
        p = 0;
        dir = 0;
      } else {
        final cents = s.shown.clamp(-55.0, 55.0);
        offset = -cents * (gap * 0.44) / 50;
        p = math.min(1.0, s.shown.abs() / 50);
        dir = s.shown < 0 ? -1 : 1;
      }
    }
    final sway = s.still ? 0.0 : math.sin(s.t * 1.6) * 2;
    final cx = cx0 + sway + (c != null ? math.sin(c.t * math.pi * 2) * 5 : 0);
    final handDx = rx * 1.12;
    StringlingFace(
      cx: cx,
      cy: anchor - ry * 0.3 + offset,
      rx: rx,
      ry: ry,
      thick: thick,
      hands: [Offset(cx0 - handDx, handL), Offset(cx0 + handDx, handR)],
      pain: p,
      dir: dir,
      t: s.t,
      held: s.held,
      idle: idle && c == null,
      still: s.still,
      accent: w.rungs[target].color,
    ).paint(canvas);

    if (w.fineTuners && !climbing && !idle && !inTune) {
      final r = math.max(9.0, math.min(13.0, gap * 0.16));
      _turnArrow(canvas, Offset(x2 - r - 10, rungY(s.rung) - r - 9), r,
          clockwise: s.shown < 0, t: s.still ? 0 : s.t);
    }

    if (inTune && s.held > 0.2) {
      _text(canvas, 'in tune', Offset(x2 - 4, rungY(target) + thick + 6),
          TextStyle(
              color: _tuned.withValues(alpha: math.min(1.0, (s.held - 0.2) * 3)),
              fontSize: 12,
              fontWeight: FontWeight.w800),
          right: true);
    }
  }

  /// A circular arrow, turning slowly the way it points.
  void _turnArrow(Canvas canvas, Offset c, double r, {required bool clockwise, required double t}) {
    final dir = clockwise ? 1.0 : -1.0;
    const sweep = math.pi * 1.45;
    final start = -math.pi / 2 + dir * t * 1.8 - dir * sweep / 2;
    final paint = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.26
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, dir * sweep, false, paint);
    // Arrowhead at the leading end, along the direction of travel.
    final end = start + dir * sweep;
    final tip = c + Offset(math.cos(end), math.sin(end)) * r;
    final along = Offset(-math.sin(end), math.cos(end)) * dir; // tangent
    final out = Offset(math.cos(end), math.sin(end));
    final h = r * 0.62;
    canvas.drawPath(
        Path()
          ..moveTo(tip.dx + along.dx * h * 0.9, tip.dy + along.dy * h * 0.9)
          ..lineTo(tip.dx + out.dx * h * 0.7, tip.dy + out.dy * h * 0.7)
          ..lineTo(tip.dx - out.dx * h * 0.7, tip.dy - out.dy * h * 0.7)
          ..close(),
        Paint()..color = _ink);
  }

  void _rung(Canvas canvas, double x1, double x2, double y, double thick, Color color,
      bool doubled, double glow, Color glowColor) {
    final paint = Paint()..color = color;
    if (glow > 0) {
      final g = Paint()
        ..color = glowColor.withValues(alpha: 0.6 * glow)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * glow);
      canvas.drawRRect(
          RRect.fromLTRBR(x1, y, x2, y + thick, Radius.circular(thick / 2)), g);
    }
    if (doubled) {
      final t = thick * 0.42;
      canvas.drawRRect(RRect.fromLTRBR(x1, y, x2, y + t, Radius.circular(t / 2)), paint);
      canvas.drawRRect(
          RRect.fromLTRBR(x1, y + thick - t, x2, y + thick, Radius.circular(t / 2)), paint);
    } else {
      canvas.drawRRect(RRect.fromLTRBR(x1, y, x2, y + thick, Radius.circular(thick / 2)), paint);
    }
  }

  void _text(Canvas canvas, String text, Offset at, TextStyle style,
      {bool center = false, bool above = false, bool right = false}) {
    final tp = TextPainter(
        text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)
      ..layout();
    var o = at;
    if (center) o -= Offset(tp.width / 2, tp.height / 2);
    if (above) o -= Offset(0, tp.height);
    if (right) o -= Offset(tp.width, 0);
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(_ClimberPainter old) => true;
}

/// One stringling hanging from its hands, with a face for [pain] from 0
/// (joy) to 1 (agony). Public so the face scale can be drawn on its own.
///
///  pain   cents   face
///  <0.08  ±3      joy: eyes shut in happy arcs, blush, open grin
///  <0.12  ±6      nearly: open eyes, a smile
///  <0.4   ±20     worried: inner brows lift, the smile flattens and turns
///  <0.62  ±31     wincing: brows knot down, one eye squeezed, a wobbly mouth
///  ≥0.62          gritted teeth; past 0.78 both eyes clamped, tears at 0.86
///                 Sweat from 0.35 (±18), a second drop from 0.65.
class StringlingFace {
  StringlingFace({
    required this.cx,
    required this.cy,
    required this.rx,
    required this.ry,
    required this.thick,
    required this.hands,
    required this.pain,
    required this.dir,
    required this.t,
    this.held = 0,
    this.idle = false,
    this.still = false,
    required this.accent,
  });

  final double cx, cy, rx, ry, thick, pain, dir, t, held;
  final List<Offset> hands;
  final bool idle, still;
  final Color accent;

  void paint(Canvas canvas) {
    final u = rx / 46;
    final p = pain;
    final shake = still ? 0.0 : math.sin(t * 43) * p * p * 3.2 * u;
    final x = cx + shake;
    final ink = Paint()..color = _ink;
    final stroke = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Arms, behind the body.
    stroke.strokeWidth = 9 * u;
    for (var i = 0; i < hands.length; i++) {
      final side = i == 0 ? -1.0 : 1.0;
      final h = hands[i];
      final sx = x + side * rx * 0.8, sy = cy - ry * 0.05;
      final mx = (sx + h.dx) / 2 + side * 5 * u, my = (sy + h.dy + thick / 2) / 2;
      canvas.drawPath(
          Path()
            ..moveTo(sx, sy)
            ..quadraticBezierTo(mx, my, h.dx, h.dy + thick / 2),
          stroke);
    }

    // Feet, kicking harder the more it hurts.
    for (final k in [-1.0, 1.0]) {
      final kick = still ? 0.0 : math.sin(t * (6 + p * 10) + k * 1.7) * (1.5 + p * 7) * u;
      canvas.drawOval(
          Rect.fromCenter(
              center: Offset(x + k * rx * 0.36, cy + ry * 0.9 + kick),
              width: rx * 0.44,
              height: ry * 0.3),
          ink);
    }

    // Body.
    canvas.drawOval(Rect.fromCenter(center: Offset(x, cy), width: 2 * rx, height: 2 * ry), ink);

    // Eyes and brows.
    final ey = cy - ry * 0.25, edx = rx * 0.34, ew = rx * 0.2, eh = ry * 0.27, pr = rx * 0.1;
    final white = Paint()..color = _white;
    final wStroke = Paint()
      ..color = _white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3.4 * u;
    final blink = idle && !still ? _blink(t) : 1.0;
    for (final side in [-1.0, 1.0]) {
      final ex = x + side * edx;
      if (!idle && p < 0.08) {
        canvas.drawArc(
            Rect.fromCircle(center: Offset(ex, ey + eh * 0.35), radius: ew * 0.95),
            math.pi * 1.12, math.pi * 0.76, false, wStroke);
      } else if (p > 0.78 || (p > 0.55 && side == 1)) {
        final w = ew * 0.9, h = eh * 0.6;
        canvas.drawPath(
            Path()
              ..moveTo(ex - side * w, ey - h)
              ..lineTo(ex + side * w * 0.6, ey)
              ..lineTo(ex - side * w, ey + h),
            wStroke);
      } else {
        final open = (p < 0.3 ? 1.0 : math.max(0.45, 1 - (p - 0.3) * 1.5)) * blink;
        if (open > 0.06) {
          final eye = Rect.fromCenter(center: Offset(ex, ey), width: 2 * ew, height: 2 * eh * open);
          canvas.save();
          canvas.clipPath(Path()..addOval(eye));
          canvas.drawOval(eye, white);
          canvas.drawCircle(Offset(ex - side * rx * 0.02, ey - dir * eh * 0.38 + (idle ? eh * 0.3 : 0)), pr, ink);
          canvas.restore();
        } else {
          canvas.drawLine(Offset(ex - ew, ey), Offset(ex + ew, ey), wStroke);
        }
      }
      if (p >= 0.12) {
        // Worry lifts the inner ends; pain knots them down.
        final bl = ew * 1.25, by = ey - eh - ry * 0.12 + (p > 0.55 ? ry * 0.05 : 0);
        final ang = p <= 0.55 ? 0.15 + (p - 0.12) * 1.1 : -(0.35 + (p - 0.55) * 0.9);
        final inner = Offset(ex - side * bl * 0.55, by - math.sin(ang) * bl * 0.5);
        final outer = Offset(ex + side * bl * 0.45, by + math.sin(ang) * bl * 0.5);
        canvas.drawLine(outer, inner, wStroke..strokeWidth = 3.2 * u);
        wStroke.strokeWidth = 3.4 * u;
      }
    }

    // Cheeks, in tune.
    if (!idle && p < 0.08) {
      final blush = Paint()..color = _blush.withValues(alpha: 0.75);
      for (final side in [-1.0, 1.0]) {
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(x + side * rx * 0.58, cy + ry * 0.08), width: rx * 0.26, height: ry * 0.16),
            blush);
      }
    }

    // Mouth.
    final mx = x, my = cy + ry * 0.2, mw = rx * 0.32, mh = ry * 0.18;
    wStroke.strokeWidth = 3.2 * u;
    if (idle) {
      canvas.drawPath(
          Path()
            ..moveTo(mx - mw * 0.55, my)
            ..quadraticBezierTo(mx, my + mh * 0.9, mx + mw * 0.55, my),
          wStroke);
    } else if (p < 0.08) {
      final mouth = Path()
        ..moveTo(mx - mw, my - mh * 0.2)
        ..quadraticBezierTo(mx, my + mh * 2.3, mx + mw, my - mh * 0.2)
        ..close();
      canvas.drawPath(mouth, white);
      canvas.save();
      canvas.clipPath(mouth);
      canvas.drawOval(
          Rect.fromCenter(center: Offset(mx, my + mh * 1.05), width: mw, height: mh),
          Paint()..color = const Color(0xFFE57373));
      canvas.restore();
    } else if (p < 0.4) {
      final k = 1 - (p - 0.08) / 0.32 * 1.6;
      canvas.drawPath(
          Path()
            ..moveTo(mx - mw * 0.75, my)
            ..quadraticBezierTo(mx, my + k * mh * 1.5, mx + mw * 0.75, my),
          wStroke);
    } else if (p < 0.62) {
      const segs = 6;
      final w = mw * 1.7, amp = mh * (0.25 + (p - 0.4) * 1.2);
      final wob = still ? 0.0 : math.sin(t * 18) * 0.25;
      final path = Path();
      for (var k = 0; k <= segs; k++) {
        final px = mx - w / 2 + w * k / segs;
        final sag = math.sin(math.pi * k / segs) * -mh * 0.4;
        final edge = k == 0 || k == segs ? 0.2 : 1.0;
        final py = my + mh * 0.15 + sag + (k.isOdd ? amp : -amp) * (1 + wob) * edge;
        k == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
      }
      canvas.drawPath(path, wStroke);
    } else {
      final w = mw * 2 * (0.78 + 0.45 * (p - 0.62) / 0.38), h = mh * 1.25;
      final top = my - h / 2 + mh * 0.2;
      canvas.drawRRect(RRect.fromLTRBR(mx - w / 2, top, mx + w / 2, top + h, Radius.circular(h * 0.35)), white);
      final teeth = Paint()
        ..color = _ink
        ..strokeWidth = 1.6 * u;
      canvas.drawLine(Offset(mx - w / 2, my + mh * 0.2), Offset(mx + w / 2, my + mh * 0.2), teeth);
      for (var k = 1; k < 5; k++) {
        final tx = mx - w / 2 + w * k / 5;
        canvas.drawLine(Offset(tx, top), Offset(tx, top + h), teeth);
      }
    }

    // Sweat and tears.
    if (p > 0.35) {
      final slide = still ? 0.0 : ((t * 0.6) % 1) * ry * 0.35;
      _drop(canvas, x + rx * 0.82, cy - ry * 0.7 + slide, 4.2 * u);
    }
    if (p > 0.65) {
      final slide = still ? 0.0 : ((t * 0.6 + 0.5) % 1) * ry * 0.35;
      _drop(canvas, x - rx * 0.86, cy - ry * 0.55 + slide, 3.6 * u);
    }
    if (p > 0.86) {
      for (final side in [-1.0, 1.0]) {
        _drop(canvas, x + side * edx, ey + eh * 1.25, 2.8 * u);
      }
    }

    // Fingers curled over the rule, on top of everything.
    final fw = math.max(5.0, rx * 0.13);
    for (final h in hands) {
      for (final j in [-1, 0, 1]) {
        final fx = h.dx + j * fw * 1.15 - fw / 2;
        canvas.drawRRect(
            RRect.fromLTRBR(fx, h.dy - fw * 0.55, fx + fw, h.dy + thick + 3 * u, Radius.circular(fw / 2)),
            ink);
      }
    }

    // Sparkles once it has settled in tune.
    if (held > 0.35) {
      final a = math.min(1.0, (held - 0.35) / 0.4);
      const spots = [
        [-1.35, -0.9, 1.0], [1.4, -1.05, 0.8], [-1.1, -1.55, 0.6], [1.0, -1.7, 0.9], [0.0, -1.85, 0.7]
      ];
      for (var k = 0; k < spots.length; k++) {
        final tw = still ? 1.0 : 0.6 + 0.4 * math.sin(t * 5 + k * 1.9);
        _star(canvas, Offset(x + spots[k][0] * rx, cy + spots[k][1] * ry), 9 * u * spots[k][2] * tw,
            (k.isOdd ? _gold : accent).withValues(alpha: a));
      }
    }
  }

  // Eyes open most of a 4.5 s cycle; a quick blink near its end.
  static double _blink(double t) {
    final d = ((t % 4.5) - 4.2) / 0.16;
    if (d <= 0 || d >= 1) return 1;
    return (2 * d - 1).abs();
  }

  static void _drop(Canvas canvas, double x, double y, double r) {
    final path = Path()
      ..moveTo(x, y - r * 1.8)
      ..cubicTo(x + r * 0.2, y - r * 1.1, x + r, y - r * 0.5, x + r, y)
      ..arcTo(Rect.fromCircle(center: Offset(x, y), radius: r), 0, math.pi, false)
      ..cubicTo(x - r, y - r * 0.5, x - r * 0.2, y - r * 1.1, x, y - r * 1.8);
    canvas.drawPath(path, Paint()..color = _sweat);
    canvas.drawCircle(Offset(x - r * 0.35, y - r * 0.15), r * 0.28,
        Paint()..color = const Color(0xBFFFFFFF));
  }

  static void _star(Canvas canvas, Offset c, double r, Color color) {
    final path = Path();
    for (var k = 0; k < 8; k++) {
      final a = k * math.pi / 4, rad = k.isOdd ? r * 0.32 : r;
      final pt = c + Offset(math.cos(a) * rad, math.sin(a) * rad);
      k == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }
}

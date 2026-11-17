import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/tuner_advice.dart' show mandolinRollsToEnd;

/// Which string of a mandolin's pair: the outside one (on the edge of the
/// neck its course sits on) or the inside one.
enum MandolinString { outer, inner }

/// A mandolin's headstock as the player sees it while playing: from above the
/// face, a little toward the G and D edge, looking back past the nut toward
/// the end. The tuner for [course] is lit, and while there is something to do
/// its button twists the way to turn it, with an arrow over its top.
///
/// The advice is how the top of the button rolls: toward the headstock end,
/// or toward the body ([mandolinRollsToEnd]). Seen end-on, clockwise loosens
/// every tuner, but the player never sees a button end-on, and the two sides
/// go opposite ways, so the picture shows the very button instead.
///
/// It is drawn in 3D by hand, a few hundred flat faces projected from a
/// fixed eye, so it needs no engine and no assets: the same model as the
/// design mock-up (a three.js page) the layout was settled on.
class MandolinHeadstock extends StatefulWidget {
  const MandolinHeadstock({
    super.key,
    required this.course,
    this.which,
    this.tighten,
    this.leftHanded = false,
    this.buttonOnly = false,
  });

  /// `'G'`, `'D'`, `'A'` or `'E'`; null lights nothing.
  final String? course;

  /// The string of the pair; null lights both.
  final MandolinString? which;

  /// True to tighten, false to loosen, null for nothing to do (in tune, or
  /// no reading): the button is lit but still.
  final bool? tighten;

  /// A mirror-image mandolin: the headstock end on the right.
  final bool leftHanded;

  /// Just the button, close up, without the headstock round it.
  final bool buttonOnly;

  @override
  State<MandolinHeadstock> createState() => _MandolinHeadstockState();
}

class _MandolinHeadstockState extends State<MandolinHeadstock> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((e) => _t.value = e.inMicroseconds / 1e6);
  final _t = ValueNotifier<double>(0);

  bool get _moving => widget.course != null && widget.tighten != null;

  @override
  void initState() {
    super.initState();
    if (_moving) _ticker.start();
  }

  @override
  void didUpdateWidget(MandolinHeadstock old) {
    super.didUpdateWidget(old);
    if (_moving && !_ticker.isActive) _ticker.start();
    if (!_moving && _ticker.isActive) {
      _ticker.stop();
      _t.value = 0;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final c = widget.course, t = widget.tighten;
    final label = c == null
        ? 'Mandolin headstock'
        : t == null
            ? 'The $c tuner'
            : 'To ${t ? 'tighten' : 'loosen'} $c, roll the top of its button toward '
                '${mandolinRollsToEnd(c, tighten: t) ? 'the headstock end' : 'the body'}';
    return Semantics(
      label: label,
      image: true,
      child: CustomPaint(
        painter: _HeadstockPainter(widget, still ? null : _t),
        size: Size.infinite,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// A little 3D. Instrument coordinates: +x toward the headstock end, +y toward
// the G/D edge (the player's side), +z out of the face (the strings' side).

class _V {
  const _V(this.x, this.y, this.z);
  final double x, y, z;
  _V operator +(_V o) => _V(x + o.x, y + o.y, z + o.z);
  _V operator -(_V o) => _V(x - o.x, y - o.y, z - o.z);
  _V operator *(double k) => _V(x * k, y * k, z * k);
  double dot(_V o) => x * o.x + y * o.y + z * o.z;
  _V cross(_V o) => _V(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  _V get unit {
    final l = math.sqrt(dot(this));
    return l == 0 ? this : this * (1 / l);
  }
}

_V _mean(Iterable<_V> ps) {
  var s = const _V(0, 0, 0);
  var n = 0;
  for (final p in ps) {
    s = s + p;
    n++;
  }
  return s * (1 / n);
}

/// A convex solid: its faces, drawn back to front within a [layer].
class _Solid {
  _Solid(this.faces, this.color, this.layer) : centre = _mean(faces.expand((f) => f));
  final List<List<_V>> faces;
  final Color color;
  final int layer;
  final _V centre;
}

/// [base] swept along [d]: two caps and a side for each edge.
_Solid _prism(List<_V> base, _V d, Color color, int layer) {
  final top = [for (final p in base) p + d];
  return _Solid([
    base,
    top,
    for (var i = 0; i < base.length; i++)
      [base[i], base[(i + 1) % base.length], top[(i + 1) % base.length], top[i]],
  ], color, layer);
}

/// A box on axes [u], [v], [w] (unit), [h] half-extents along each.
_Solid _box(_V c, _V h, Color color, int layer,
    {_V u = const _V(1, 0, 0), _V v = const _V(0, 1, 0), _V w = const _V(0, 0, 1)}) {
  final base = [
    c - u * h.x - v * h.y - w * h.z,
    c + u * h.x - v * h.y - w * h.z,
    c + u * h.x + v * h.y - w * h.z,
    c - u * h.x + v * h.y - w * h.z,
  ];
  return _prism(base, w * (2 * h.z), color, layer);
}

/// A cylinder along unit [axis], centred on [c]; [r2] makes it oval (along
/// [v], the second cross axis).
_Solid _cylinder(_V c, _V axis, double r, double length, Color color, int layer,
    {int sides = 14, double? r2, _V? across}) {
  final u = (across ?? (axis.cross(const _V(0, 0, 1)).dot(axis.cross(const _V(0, 0, 1))) < 1e-6
          ? const _V(1, 0, 0)
          : axis.cross(const _V(0, 0, 1))))
      .unit;
  final v = axis.cross(u).unit;
  final start = c - axis * (length / 2);
  final base = [
    for (var i = 0; i < sides; i++)
      start + u * (r * math.cos(2 * math.pi * i / sides)) + v * ((r2 ?? r) * math.sin(2 * math.pi * i / sides)),
  ];
  return _prism(base, axis * length, color, layer);
}

const _wood = Color(0xFFB9773C);
const _neckWood = Color(0xFF8A5A2E);
const _board = Color(0xFF3B2A22);
const _metal = Color(0xFFC9C4B6);
const _bone = Color(0xFFF3EAD6);
const _lit = Color(0xFFF2B705);
const _tight = Color(0xFFD9480F);
const _loose = Color(0xFF1C7ED6);
const _label = Color(0xFF6A6180);

/// Posts from the nut toward the end. The outside string of each pair has the
/// post nearer the nut, so no string crosses another (and a player's G and E
/// outside strings are on the buttons closest to the body).
const _posts = [0.95, 1.65, 2.35, 3.05];
const _near = [('G', MandolinString.outer), ('G', MandolinString.inner), ('D', MandolinString.outer), ('D', MandolinString.inner)];
const _far = [('E', MandolinString.outer), ('E', MandolinString.inner), ('A', MandolinString.outer), ('A', MandolinString.inner)];

/// Across the nut, from the G/D edge to the A/E edge.
const _across = [
  ('G', MandolinString.outer), ('G', MandolinString.inner), ('D', MandolinString.outer), ('D', MandolinString.inner),
  ('A', MandolinString.inner), ('A', MandolinString.outer), ('E', MandolinString.inner), ('E', MandolinString.outer),
];

bool _nearSide(String course) => course == 'G' || course == 'D';

class _HeadstockPainter extends CustomPainter {
  _HeadstockPainter(this.w, this.t) : super(repaint: t);
  final MandolinHeadstock w;
  final ValueNotifier<double>? t;

  bool _isLit(String c, MandolinString s) => c == w.course && (w.which == null || w.which == s);

  /// The twist: a quarter turn the right way, a rest, and again.
  double get _spin {
    final tighten = w.tighten, c = w.course, time = t?.value;
    if (tighten == null || c == null || time == null) return 0;
    final k = math.min(1.0, (time % 2.2) / 1.4);
    final roll = mandolinRollsToEnd(c, tighten: tighten) ? 1.0 : -1.0;
    return roll * (math.pi / 2.2) * (k * k * (3 - 2 * k));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final mx = w.leftHanded ? -1.0 : 1.0;
    _V m(_V p) => _V(p.x * mx, p.y, p.z); // a mirror-image mandolin

    // Where the lit button is (the first, if both are).
    final course = w.course;
    var bx = _posts[0], by = 1.82;
    if (course != null) {
      final row = _nearSide(course) ? _near : _far;
      final i = row.indexWhere((e) => e.$1 == course && (w.which == null || e.$2 == w.which));
      bx = _posts[i];
      if (w.which == null) bx = (_posts[i] + _posts[i + 1]) / 2;
      by = _nearSide(course) ? 1.82 : -1.82;
    }

    // The eye: above the face, toward the G/D edge, back toward the body.
    final _V target, eye;
    final List<_V> fit;
    if (w.buttonOnly) {
      target = _V(bx, by, 0);
      eye = _V(bx - 1.3, by + 1.5, 2.6);
      fit = [
        for (final dx in [-0.75, 0.75])
          for (final dy in [-0.45, 0.45])
            for (final dz in [-0.45, 0.75]) _V(bx + dx, by + dy, dz),
      ];
    } else {
      target = const _V(1.2, 0, 0);
      eye = const _V(-3.0, 4.6, 7.4);
      fit = [
        for (final x in [-0.5, 3.95])
          for (final y in [-2.2, 2.2])
            for (final z in [-0.3, 0.45]) _V(x, y, z),
      ];
    }
    final e = m(eye), tg = m(target);
    final zc = (e - tg).unit;
    final xc = const _V(0, -1, 0.35).cross(zc).unit;
    final yc = zc.cross(xc);
    const focal = 1.0;
    Offset raw(_V p) {
      final d = m(p) - e;
      final depth = -d.dot(zc);
      return Offset(focal * d.dot(xc) / depth, -focal * d.dot(yc) / depth);
    }

    double depthOf(_V p) => -(m(p) - e).dot(zc);

    // Fit the view to the box.
    var l = double.infinity, r = -double.infinity, top = double.infinity, bot = -double.infinity;
    for (final p in fit) {
      final o = raw(p);
      l = math.min(l, o.dx);
      r = math.max(r, o.dx);
      top = math.min(top, o.dy);
      bot = math.max(bot, o.dy);
    }
    final scale = math.min(size.width / (r - l), size.height / (bot - top)) * 0.94;
    final off = Offset(size.width / 2 - scale * (l + r) / 2, size.height / 2 - scale * (top + bot) / 2);
    Offset at(_V p) => raw(p) * scale + off;
    // Points per unit of the model where the eye is looking, for line widths.
    final unit = ((at(target + const _V(0.5, 0, 0)) - at(target - const _V(0.5, 0, 0))).distance +
            (at(target + const _V(0, 0.5, 0)) - at(target - const _V(0, 0.5, 0))).distance) /
        2;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // The model.
    final solids = <_Solid>[];
    final full = !w.buttonOnly;
    if (full) {
      solids.add(_cylinder(const _V(-9.2, 0, -0.5), const _V(0, 0, 1), 3.6, 0.9, _wood, 0, sides: 40));
      solids.add(_box(const _V(-3, 0, -0.18), const _V(3, 0.575, 0.225), _neckWood, 0));
      solids.add(_box(const _V(-3, 0, 0.08), const _V(3, 0.525, 0.04), _board, 0));
      // The headstock: rounded at its end.
      final outline = <_V>[const _V(0, -1, -0.2)];
      for (var i = 0; i <= 6; i++) {
        final a = -math.pi / 2 + math.pi / 2 * i / 6;
        outline.add(_V(3.35 + 0.55 * math.cos(a), -0.45 + 0.55 * math.sin(a), -0.2));
      }
      for (var i = 0; i <= 6; i++) {
        final a = math.pi / 2 * i / 6;
        outline.add(_V(3.35 + 0.55 * math.cos(a), 0.45 + 0.55 * math.sin(a), -0.2));
      }
      outline.add(const _V(0, 1, -0.2));
      solids.add(_prism(outline, const _V(0, 0, 0.36), _wood, 0));
      solids.add(_box(const _V(0, 0, 0.14), const _V(0.05, 0.55, 0.08), _bone, 1));
      for (var f = 1; f < 3; f++) {
        solids.add(_box(_V(-0.95 * f, 0, 0.13), const _V(0.02, 0.525, 0.015), _metal, 1));
      }
    }
    final spin = _spin;
    final arrows = <(_V, double, bool)>[]; // (centre, which way, tighten)
    for (final (row, sy) in [(_near, 1.0), (_far, -1.0)]) {
      for (var i = 0; i < row.length; i++) {
        final (c, s) = row[i];
        final on = _isLit(c, s);
        if (!full && !on) continue;
        final px = _posts[i];
        if (full) {
          solids.add(_cylinder(_V(px, 0.55 * sy, 0.25), const _V(0, 0, 1), 0.07, 0.3, _metal, 1, sides: 10));
          solids.add(_box(_V(px, 1.0 * sy, -0.08), const _V(0.18, 0.15, 0.14), _metal, 1));
        }
        solids.add(_cylinder(_V(px, 1.35 * sy, -0.04), const _V(0, 1, 0), 0.05, 0.6, _metal, 2, sides: 8));
        final centre = _V(px, 1.82 * sy, -0.04);
        final a = on ? spin : 0.0;
        final axis = _V(math.sin(a), 0, math.cos(a)); // the button's flat faces
        final across = _V(math.cos(a), 0, -math.sin(a));
        solids.add(_cylinder(centre, axis, 0.3, 0.13, on ? _lit : _bone, 2, sides: 22, r2: 0.36, across: across));
        if (on && w.tighten != null) {
          solids.add(_box(centre + axis * 0.07, const _V(0.035, 0.31, 0.012), w.tighten! ? _tight : _loose, 3,
              u: across, v: const _V(0, 1, 0), w: axis));
          arrows.add((centre, mandolinRollsToEnd(c, tighten: w.tighten!) ? 1.0 : -1.0, w.tighten!));
        }
      }
    }

    // Back to front: by layer, then by distance.
    solids.sort((a, b) {
      final byLayer = a.layer.compareTo(b.layer);
      return byLayer != 0 ? byLayer : depthOf(b.centre).compareTo(depthOf(a.centre));
    });
    const light = _V(-0.3, 0.5, 0.9);
    final lightU = light.unit;
    final fill = Paint()..isAntiAlias = true;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..isAntiAlias = true;
    void drawSolid(_Solid s) {
      for (final f in s.faces) {
        final fc = _mean(f);
        var n = (f[1] - f[0]).cross(f[2] - f[0]).unit;
        if (n.dot(fc - s.centre) < 0) n = n * -1;
        final mn = _V(n.x * mx, n.y, n.z);
        if (mn.dot(e - m(fc)) <= 0) continue; // faces away
        final k = 0.62 + 0.38 * math.max(0.0, mn.dot(lightU));
        final path = Path()..addPolygon([for (final p in f) at(p)], true);
        fill.color = Color.lerp(Colors.black, s.color, k)!;
        canvas.drawPath(path, fill);
        edge.color = Color.lerp(Colors.black, s.color, k * 0.8)!;
        canvas.drawPath(path, edge);
      }
    }

    for (final s in solids.where((s) => s.layer <= 1)) {
      drawSolid(s);
    }
    if (full) {
      final string = Paint()..strokeCap = StrokeCap.round;
      for (var j = 0; j < _across.length; j++) {
        final (c, s) = _across[j];
        final row = _nearSide(c) ? _near : _far;
        final i = row.indexOf((c, s));
        final y0 = 0.42 - j * 0.12, sy = _nearSide(c) ? 1.0 : -1.0;
        final on = _isLit(c, s);
        string
          ..color = on ? _lit : _metal
          ..strokeWidth = math.max(on ? 1.4 : 0.6, unit * (on ? 0.03 : 0.016));
        final path = Path()
          ..moveTo(at(_V(-1.6, y0, 0.22)).dx, at(_V(-1.6, y0, 0.22)).dy)
          ..lineTo(at(_V(0, y0, 0.22)).dx, at(_V(0, y0, 0.22)).dy)
          ..lineTo(at(_V(_posts[i], 0.55 * sy, 0.3)).dx, at(_V(_posts[i], 0.55 * sy, 0.3)).dy);
        canvas.drawPath(path, string..style = PaintingStyle.stroke);
      }
    }
    for (final s in solids.where((s) => s.layer >= 2)) {
      drawSolid(s);
    }

    // The arrows: over the top of the button, the way its top rolls.
    for (final (c, way, tighten) in arrows) {
      const rad = 0.62, sweep = 1.0;
      final pts = [
        for (var k = 0; k <= 16; k++)
          () {
            final a = -way * sweep + 2 * way * sweep * k / 16;
            return c + _V(rad * math.sin(a), 0, rad * math.cos(a));
          }(),
      ];
      final colour = tighten ? _tight : _loose;
      final stroke = Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.0, unit * 0.07)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()..addPolygon([for (final p in pts) at(p)], false);
      canvas.drawPath(path, stroke);
      final end = pts.last, before = pts[pts.length - 2];
      final tip = at(end), dir = tip - at(before);
      final u = dir / dir.distance;
      final perp = Offset(-u.dy, u.dx);
      final hl = math.max(6.0, unit * 0.22), hw = hl * 0.6;
      canvas.drawPath(
          Path()
            ..addPolygon([tip + u * hl, tip + perp * hw, tip - perp * hw], true),
          Paint()..color = colour);
    }

    // Which way is which: in the top corners, out of the drawing's way, each
    // with an arrow pointing the way it names.
    final endOnLeft = !w.leftHanded;
    final style = const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _label);
    for (final (text, left) in [
      (endOnLeft ? '← headstock end' : 'headstock end →', endOnLeft),
      (endOnLeft ? 'body →' : '← body', !endOnLeft),
    ]) {
      final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(left ? 6 : size.width - tp.width - 6, 4));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HeadstockPainter old) =>
      old.w.course != w.course ||
      old.w.which != w.which ||
      old.w.tighten != w.tighten ||
      old.w.leftHanded != w.leftHanded ||
      old.w.buttonOnly != w.buttonOnly ||
      old.t != t;
}

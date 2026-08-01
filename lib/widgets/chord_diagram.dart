import 'package:flutter/material.dart';
import '../models/chord_shape.dart';
import 'chord_swatch.dart';

/// A single mandolin chord diagram, drawn **horizontally** so its string order
/// matches the tab stave: strings run left→right (nut→frets), stacked high→low
/// top→bottom (E, A, D, G). This is the deliberate "tab stave frozen" look —
/// axis agreement with the tab, not a conventional vertical grid.
class ChordDiagram extends StatelessWidget {
  final ChordShape shape;

  /// Optional scale-degree numeral (e.g. `I`, `V`, `vi`). When given, the header
  /// becomes a [ChordPill] reading `I (A)` — *the same pill the staff's chord
  /// lane draws*, at the same size and in the same colour. The point is that the
  /// footer header IS the bar you are hunting for on the staff, rather than a
  /// separate legend you have to translate. Without it the header falls back to
  /// the plain chord name.
  final String? degree;

  /// Scale-degree index (0 = I … 6 = VII) and quality, which pick the pill's
  /// colour and shade. Ignored when [degree] is null.
  ///
  /// The grid itself stays monochrome on purpose: it is notation, and coloured
  /// notation is harder to read than a coloured header.
  final int? degreeIndex;
  final bool minorQuality;

  final double width;
  final double height;

  const ChordDiagram(
    this.shape, {
    super.key,
    this.degree,
    this.degreeIndex,
    this.minorQuality = false,
    this.width = 140,
    this.height = 66,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (degree != null)
          // Degree-primary, one weight throughout: `I` says what the chord does
          // and `(A)` says which shape to grab — you need to read both.
          ChordPill(
            label: '$degree (${shape.name})',
            degree: degreeIndex,
            minor: minorQuality,
          )
        else
          Text(shape.name,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: color)),
        const SizedBox(height: 6),
        CustomPaint(
          size: Size(width, height),
          painter: _ChordDiagramPainter(shape, color),
        ),
      ],
    );
  }
}

class _ChordDiagramPainter extends CustomPainter {
  final ChordShape shape;
  final Color color;

  _ChordDiagramPainter(this.shape, this.color);

  // Source frets are [G, D, A, E] (low→high); the diagram shows high→low
  // top→bottom, so display row r maps to source index (3 - r).
  int? _fretForRow(int row) => shape.frets[3 - row];
  int? _fingerForRow(int row) =>
      (shape.fingers != null) ? shape.fingers![3 - row] : null;

  @override
  void paint(Canvas canvas, Size size) {
    const gutter = 16.0; // left space for open/muted markers + base-fret label
    const pad = 5.0;
    final left = gutter;
    final right = size.width - pad;
    final top = pad;
    final bottom = size.height - pad;
    final rowGap = (bottom - top) / 3; // 4 strings → 3 gaps
    final cols = shape.maxFret <= 4 ? 4 : shape.maxFret - (shape.baseFret - 1);
    final cellW = (right - left) / cols;

    final line = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final nut = Paint()
      ..color = color
      ..strokeWidth = 3;
    final dot = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final open = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    // String lines (horizontal).
    for (int r = 0; r < 4; r++) {
      final y = top + r * rowGap;
      canvas.drawLine(Offset(left, y), Offset(right, y), line);
    }
    // Fret lines (vertical); leftmost is the thick nut when at base position 1.
    for (int c = 0; c <= cols; c++) {
      final x = left + c * cellW;
      canvas.drawLine(Offset(x, top), Offset(x, bottom),
          (c == 0 && shape.baseFret == 1) ? nut : line);
    }

    // Base-fret label for barre positions (e.g. "3").
    if (shape.baseFret > 1) {
      _paintText(canvas, '${shape.baseFret}', 9,
          color.withValues(alpha: 0.7), Offset(2, top - 1), center: false);
    }

    // Per-string markers.
    for (int r = 0; r < 4; r++) {
      final y = top + r * rowGap;
      final f = _fretForRow(r);
      if (f == null) {
        _paintText(canvas, '×', 12, color.withValues(alpha: 0.7),
            Offset(left - 8, y));
        continue;
      }
      if (f == 0) {
        canvas.drawCircle(Offset(left - 8, y), 3.2, open);
        continue;
      }
      final rf = f - (shape.baseFret - 1); // fret within the visible window
      final cx = left + (rf - 0.5) * cellW;
      final radius = (rowGap < cellW ? rowGap : cellW) * 0.42;
      canvas.drawCircle(Offset(cx, y), radius, dot);
      final finger = _fingerForRow(r);
      if (finger != null && finger > 0) {
        _paintText(canvas, '$finger', radius * 1.25,
            const Color(0xFFFFFFFF), Offset(cx, y));
      }
    }
  }

  /// Paints [s]; when [center] is true, [at] is the glyph's center, otherwise
  /// its top-left.
  void _paintText(Canvas canvas, String s, double size, Color c, Offset at,
      {bool center = true}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              fontSize: size, color: c, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    final origin = center
        ? Offset(at.dx - tp.width / 2, at.dy - tp.height / 2)
        : at;
    tp.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(covariant _ChordDiagramPainter old) =>
      old.shape != shape || old.color != color;
}

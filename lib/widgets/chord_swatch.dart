import 'package:flutter/material.dart';

import '../models/chord_palette.dart';

/// Label metrics as fractions of the swatch height, shared by the staff's chord
/// lane and the footer pills so the two are the same object at two sizes rather
/// than two things that merely look alike.
const chordLabelSizeFraction = 0.66;
const chordLabelInsetFraction = 0.34;

/// Corner radius as a fraction of the swatch height.
const chordSwatchRadiusFraction = 0.35;

/// Text style for a chord label on a swatch of [height] filled with [fill].
///
/// One weight and one size for the whole string: the degree and the chord name
/// are both things you read off the bar (`I` tells you the function, `(A)` tells
/// you which shape to grab), so neither is subordinate to the other.
TextStyle chordLabelStyle(double height, Color fill) => TextStyle(
      fontSize: height * chordLabelSizeFraction,
      height: 1.0,
      fontWeight: FontWeight.w700,
      color: ChordPalette.inkOn(fill),
    );

/// Paints the chord swatch — the one visual token shared by the staff's chord
/// lane and the "New chords" footer. Both go through here so a bar and its
/// diagram are matched by eye rather than by two independently maintained fills;
/// that lookup is the whole point of coloring them.
///
/// A flat fill in the degree's color, except degree III
/// ([ChordPalette.hatchedDegree]), which is drawn as diagonal hashes because it
/// pulls towards both II and IV and is rare enough that picking one would be
/// arbitrary.
///
/// Every swatch also gets a hairline edge in a darkened version of its own fill.
/// That is not decoration: the palette spans from saturated red to parchment, and
/// measured on the staff the parchment I bar was almost invisible against the
/// page — which defeats the whole purpose, since the bar exists to show a chord's
/// EXTENT. The edge defines the shape without touching the hue.
void paintChordSwatch(
  Canvas canvas,
  RRect rrect, {
  required int? degree,
  required bool minor,
}) {
  final fill = ChordPalette.of(degree, minor: minor);
  canvas.drawRRect(rrect, Paint()..color = fill);
  final r = rrect.outerRect;

  if (degree == ChordPalette.hatchedDegree) {
    final alt =
        minor ? ChordPalette.dim(ChordPalette.iiiAlt) : ChordPalette.iiiAlt;
    // Hash metrics scale off the swatch height, so they read the same on a
    // full-height lane bar and on a footer pill.
    final hatch = Paint()
      ..color = alt
      ..strokeWidth = r.height * 0.34
      ..style = PaintingStyle.stroke;
    canvas.save();
    canvas.clipRRect(rrect);
    for (var x = r.left - r.height; x < r.right + r.height; x += r.height) {
      canvas.drawLine(Offset(x, r.bottom), Offset(x + r.height, r.top), hatch);
    }
    canvas.restore();
  }

  final edgeWidth = (r.height * 0.07).clamp(1.0, 2.0);
  canvas.drawRRect(
    rrect.deflate(edgeWidth / 2),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = edgeWidth
      ..color = ChordPalette.dim(ChordPalette.dim(fill)).withValues(alpha: 0.8),
  );
}

/// A labelled chord pill — the staff's chord bar as a standalone widget, sized to
/// its label.
///
/// Used as the "New chords" footer header so a diagram is topped by *the thing
/// you are looking for on the staff*, at the same size and in the same style,
/// rather than by a separate colour legend you have to translate.
class ChordPill extends StatelessWidget {
  /// Degree-primary, e.g. `I (A)` — the same string the lane bar carries.
  final String label;
  final int? degree;
  final bool minor;

  /// Matches a chord lane bar at a typical zoom.
  final double height;

  const ChordPill({
    super.key,
    required this.label,
    required this.degree,
    required this.minor,
    this.height = 22,
  });

  @override
  Widget build(BuildContext context) {
    final fill = ChordPalette.of(degree, minor: minor);
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _ChordSwatchPainter(degree, minor),
        child: Center(
          widthFactor: 1,
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: height * chordLabelInsetFraction),
            child: Text(label, style: chordLabelStyle(height, fill)),
          ),
        ),
      ),
    );
  }
}

class _ChordSwatchPainter extends CustomPainter {
  final int? degree;
  final bool minor;

  _ChordSwatchPainter(this.degree, this.minor);

  @override
  void paint(Canvas canvas, Size size) {
    paintChordSwatch(
      canvas,
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(size.height * chordSwatchRadiusFraction),
      ),
      degree: degree,
      minor: minor,
    );
  }

  @override
  bool shouldRepaint(_ChordSwatchPainter old) =>
      old.degree != degree || old.minor != minor;
}

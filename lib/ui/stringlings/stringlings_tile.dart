import 'package:flutter/material.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../splash/stringlings_art.g.dart';

/// The app icon as a tile: the generated art, with its eyes painted on top so
/// they can blink ([big] and [little] are how open each stringling's eyes are,
/// 1 = open, 0 = shut). The launch splash draws it at [kLaunchTileSize] with
/// [shadow], as the native launch image does; the iPad piece list draws a
/// small one beside the app's name.
class StringlingsTile extends StatelessWidget {
  const StringlingsTile({
    super.key,
    required this.size,
    this.shadow = false,
    this.big = 1,
    this.little = 1,
  });

  final double size;
  final bool shadow;
  final double big, little;

  static final ScalableImage _art =
      ScalableImage.fromSvgString(kStringlingsIconSvg);

  @override
  Widget build(BuildContext context) {
    // The iOS icon corner radius.
    final radius = BorderRadius.circular(size * 0.2237);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        // CSS blur 18 is a Gaussian sigma of 9; Flutter's blurRadius 15 is
        // sigma 15 × 0.577 + 0.5 ≈ 9.2.
        boxShadow: shadow
            ? const [
                BoxShadow(
                    color: Color(0x2E2B2340), offset: Offset(0, 6), blurRadius: 15),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: CustomPaint(
          foregroundPainter: _EyesPainter(big: big, little: little),
          child: ScalableImageWidget(si: _art, fit: BoxFit.fill),
        ),
      ),
    );
  }
}

class _EyesPainter extends CustomPainter {
  _EyesPainter({required this.big, required this.little});

  final double big, little;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 1024;
    final white = Paint()..color = kStringlingsEyeWhite;
    final pupil = Paint()..color = kStringlingsPupil;
    for (var i = 0; i < kStringlingsEyes.length; i++) {
      final open = i < 2 ? big : little;
      if (open < 0.04) continue; // shut: the head shows through
      final [cx, cy, rx, ry, px, py, pr] = kStringlingsEyes[i];
      final eye = Rect.fromCenter(
          center: Offset(cx * k, cy * k), width: 2 * rx * k, height: 2 * ry * k * open);
      canvas.save();
      canvas.clipPath(Path()..addOval(eye));
      canvas.drawOval(eye, white);
      canvas.drawCircle(Offset(px * k, py * k), pr * k, pupil);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_EyesPainter old) => old.big != big || old.little != little;
}

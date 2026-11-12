import 'package:flutter/material.dart';
import 'package:jovial_svg/jovial_svg.dart';

import 'stringlings_art.g.dart';

/// The cold-launch splash: the two stringlings blink, then the app fades in.
///
/// It takes over from the native launch screen (iOS LaunchScreen.storyboard,
/// Android launch_background.xml), which shows the same icon tile at the same
/// size, centred on the same paper colour. So the first Flutter frame looks
/// identical to the native screen and the only visible change is the blink.
/// Change the art in scripts/app_icon/stringlings_icon.mjs, not here.
///
/// The app is built underneath from the first frame ([child] is always in the
/// tree), so the piece list main() preloaded is ready when the splash fades.
/// A tap skips straight to the fade. With reduced motion on, nothing blinks.
class LaunchSplash extends StatefulWidget {
  const LaunchSplash({super.key, required this.child});

  final Widget child;

  @override
  State<LaunchSplash> createState() => _LaunchSplashState();
}

/// Timeline, in milliseconds from the first frame. The big stringling blinks,
/// then the little one, a beat later.
const _bigBlinkAt = 300.0;
const _littleBlinkAt = 390.0;
const _blinkLength = 170.0; // closed at the midpoint
const _fadeAt = 850.0;
const _fadeLength = 300.0;
const _total = _fadeAt + _fadeLength;

const _paper = Color(0xFFFFF9EE);

class _LaunchSplashState extends State<LaunchSplash>
    with SingleTickerProviderStateMixin {
  static final ScalableImage _art =
      ScalableImage.fromSvgString(kStringlingsIconSvg);

  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _total ~/ 1),
  )
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) setState(() => _done = true);
    })
    ..forward();

  bool _done = false;

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  void _skip() {
    final fadeStart = _fadeAt / _total;
    if (_clock.value < fadeStart) _clock.forward(from: fadeStart);
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _skip,
          child: AnimatedBuilder(
            animation: _clock,
            builder: (context, _) {
              final t = _clock.value * _total;
              final fade = ((t - _fadeAt) / _fadeLength).clamp(0.0, 1.0);
              return Opacity(
                opacity: 1 - Curves.easeOut.transform(fade),
                child: ColoredBox(
                  color: _paper,
                  child: Center(
                    child: _Tile(
                      art: _art,
                      big: still ? 1 : _openness(t, _bigBlinkAt),
                      little: still ? 1 : _openness(t, _littleBlinkAt),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// How open the eyes are at time [t] for a blink starting at [start]:
/// 1 = open, 0 = shut.
double _openness(double t, double start) {
  final d = (t - start) / _blinkLength;
  if (d <= 0 || d >= 1) return 1;
  return Curves.easeInOut.transform((2 * d - 1).abs());
}

/// The icon tile as the native launch image draws it: 160 pt, the iOS corner
/// radius, and the same soft shadow (CSS `0 6px 18px` in the .mjs).
class _Tile extends StatelessWidget {
  const _Tile({required this.art, required this.big, required this.little});

  final ScalableImage art;
  final double big, little;

  @override
  Widget build(BuildContext context) {
    const size = kLaunchTileSize;
    final radius = BorderRadius.circular(size * 0.2237);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        // CSS blur 18 is a Gaussian sigma of 9; Flutter's blurRadius 15 is
        // sigma 15 × 0.577 + 0.5 ≈ 9.2.
        boxShadow: const [
          BoxShadow(color: Color(0x2E2B2340), offset: Offset(0, 6), blurRadius: 15),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: CustomPaint(
          foregroundPainter: _EyesPainter(big: big, little: little),
          child: ScalableImageWidget(si: art, fit: BoxFit.fill),
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

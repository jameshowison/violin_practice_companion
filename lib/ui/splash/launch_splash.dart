import 'package:flutter/material.dart';
import '../../theme/brand.dart';
import '../stringlings/stringlings_tile.dart';
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
const _bigBlinkAt = 80.0;
const _littleBlinkAt = 170.0;
const _blinkLength = 170.0; // closed at the midpoint
const _fadeAt = 630.0;
const _fadeLength = 300.0;
const _total = _fadeAt + _fadeLength;


class _LaunchSplashState extends State<LaunchSplash>
    with SingleTickerProviderStateMixin {
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
                  color: kIconPaper,
                  child: Center(
                    child: StringlingsTile(
                      size: kLaunchTileSize,
                      shadow: true,
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

import 'package:flutter/material.dart';

import '../models/count_in.dart';

/// The count-off, drawn as `1 .. 2 .. 3 ..` reading left to right into the music.
///
/// The numbers are the BAR's beats, not a tally, so a count that runs two bars
/// reads `1 .. 2 .. 3 .. 4 .. 1 .. 2 ..` — which is how a count-off is spoken, and
/// the only way "the pickup is beat four" can be read off the display.
///
/// The whole sequence is shown from the first beat, not revealed one number at a
/// time: the useful information at beat one is *how long you have*, and a
/// progressive reveal withholds exactly that. The beat being counted is coloured;
/// the ones already counted stay legible but recede, and the ones still to come
/// are faint. Nothing changes width as the count advances (one weight, tabular
/// figures) so the row doesn't wobble on every beat.
///
/// The trailing dots are the point of the shape — they run off the end of the
/// sequence towards the first note, which is what makes the count read as
/// leading into the music rather than as a bare tally.
class CountInLabel extends StatelessWidget {
  const CountInLabel({super.key, required this.tick, required this.height});

  final CountInTick tick;

  /// Height available to the label; the type is sized from it so the count
  /// scales with the notation lane it sits in.
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = (height * 0.66).clamp(11.0, 30.0);
    final counted = scheme.onSurface.withValues(alpha: 0.50);
    final toCome = scheme.onSurface.withValues(alpha: 0.22);
    final now = scheme.primary;

    Color colorFor(int i) =>
        i == tick.index ? now : (i < tick.index ? counted : toCome);

    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: size * 0.45),
      decoration: BoxDecoration(
        // A pill, because the lane it lands in may already hold a chord bar —
        // the count-off is transient and has to stay readable over whatever it
        // covers for its two seconds. Fully opaque, not a wash: at 92% the
        // chord bar's rounded cap ghosted through and read as a box drawn round
        // one of the numbers.
        color: scheme.surface,
        borderRadius: BorderRadius.circular(size * 0.45),
      ),
      // `widthFactor: 1` is load-bearing: it centres the numbers in the band's
      // HEIGHT while leaving the pill exactly as wide as the text. A plain
      // `alignment` would make the box expand to whatever width it was offered
      // and centre the count inside that instead — which quietly unpins it from
      // the time signature it is supposed to sit above.
      child: Align(
        widthFactor: 1,
        child: Text.rich(
          TextSpan(
            style: TextStyle(
              fontSize: size,
              height: 1.0,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            children: [
              for (var i = 0; i < tick.labels.length; i++) ...[
                if (i > 0)
                  TextSpan(text: ' .. ', style: TextStyle(color: toCome)),
                TextSpan(
                    text: '${tick.labels[i]}',
                    style: TextStyle(color: colorFor(i))),
              ],
              TextSpan(text: ' ..', style: TextStyle(color: toCome)),
            ],
          ),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
        ),
      ),
    );
  }
}

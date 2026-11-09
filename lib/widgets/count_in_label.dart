import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/count_in.dart';

/// Apex of an ordinary hop between two counted beats, and of the last one —
/// the hop into the first note — as fractions of the font size.
///
/// The last is twice the height on purpose. It is the conductor's preparatory
/// beat, or the first violin's breath and nod: the gesture before the downbeat
/// is the biggest one, and its rise and fall is what tells the player exactly
/// when to come in. A count that only flashes numbers says "now" after the
/// fact; a moving dot says it in advance.
const _hopLift = 0.35, _breathLift = 0.7;

/// Where the count-in's bouncing dot is at [beat] (fractional counted beats
/// since the count began; see `PlaybackServiceBase.countInBeatPosition`), for
/// a count of [labelCount] numbers landing on the first note at [totalBeats].
///
/// The numbers stand in equal slots, one per beat, and the landing is where
/// the next one would be, so x is simply the beat: the dot covers the same
/// distance in every beat and moves at the pulse's own steady speed. (Spacing
/// it by the text — `1 .. 2 ..`, with a bar line taking room of its own —
/// made the dot speed up and slow down.) A sub-beat pickup lands it short of
/// the next slot, and lead rests after the last number carry it past.
///
/// It rests on number `k` at beat `k` and hops, along a parabola, to `k+1`;
/// the last hop runs from the last number to the landing. Returns x in slots
/// from the first number's centre, and the lift above the resting line in
/// font-size units — 0 exactly on every beat, the moment the dot touches down.
({double x, double lift}) countInDotOffset(
    double beat, double totalBeats, int labelCount) {
  if (labelCount <= 0 || totalBeats <= 0 || beat <= 0) return (x: 0, lift: 0);
  if (beat >= totalBeats) return (x: totalBeats, lift: 0);
  final k = beat.floor().clamp(0, labelCount - 1);
  final isLast = k == labelCount - 1;
  final end = isLast ? totalBeats : (k + 1).toDouble();
  final span = end - k;
  final t = span <= 0 ? 1.0 : ((beat - k) / span).clamp(0.0, 1.0);
  final lift = 4 * t * (1 - t) * (isLast ? _breathLift : _hopLift);
  return (x: beat, lift: lift);
}

/// Where the count-in's bar lines fall, in slots from the first number's
/// centre: midway between the last beat of a bar and the 1 that follows it,
/// so they sit in the gap the numbers already leave and add no width. A count
/// that fills its last bar is closed by one too, before the landing; one cut
/// short by a pickup is left open.
List<double> countInBarlines(List<int> labels, int perBar) => [
      for (var i = 0; i + 1 < labels.length; i++)
        if (labels[i + 1] == 1) i + 0.5,
      if (labels.isNotEmpty && perBar > 0 && labels.last == perBar)
        labels.length - 0.5,
    ];

/// The count-off, drawn as `1 2 3 | 1 2 3 |` reading left to right into the
/// music, right-aligned in whatever width it's given.
///
/// The numbers are the BAR's beats, not a tally, so a count that runs two bars
/// reads `1 2 3 4 | 1 2` — which is how a count-off is spoken, and the only
/// way "the pickup is beat four" can be read off the display. Each number has
/// a slot of the same width, with the bar lines in the gaps (see
/// [countInBarlines]), so beats are evenly spaced however the bars fall.
///
/// The whole sequence is shown from the first beat, not revealed one number at a
/// time: the useful information at beat one is *how long you have*, and a
/// progressive reveal withholds exactly that. The beat being counted is coloured;
/// the ones already counted stay legible but recede, and the ones still to come
/// are faint. Nothing changes width as the count advances (one weight, tabular
/// figures) so the row doesn't wobble on every beat.
///
/// The slot after the last number is left empty: it is the first note, where
/// the dot lands.
///
/// With [beatPosition] given, a dot bounces from number to number in time (see
/// [countInDotOffset]), animated per frame rather than per playback tick. While
/// [CountInTick.introProgress] is set — a recording's intro is still playing —
/// a quiet "Intro" and its progress sit at the left end, the count still to
/// come at the right.
class CountInLabel extends StatefulWidget {
  const CountInLabel(
      {super.key, required this.tick, required this.height, this.beatPosition});

  final CountInTick tick;

  /// Height available to the numbers; the type is sized from it so the count
  /// scales with the lane it sits in. The dot's arc adds headroom above.
  final double height;

  /// Fractional counted beats elapsed, or null when not counting; read every
  /// frame. Null disables the dot.
  final double? Function()? beatPosition;

  @override
  State<CountInLabel> createState() => _CountInLabelState();
}

class _CountInLabelState extends State<CountInLabel>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _beat = ValueNotifier(0);

  // Whether this count opened with an intro. The intro block then stays,
  // full, for the rest of the count: dropping it would hand its width to the
  // count, which (scaled down to fit) would jump in size on its first beat.
  bool _hadIntro = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      final b = widget.beatPosition?.call();
      if (b != null) _beat.value = b;
    });
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant CountInLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    final want =
        widget.beatPosition != null && widget.tick.introProgress == null;
    if (want && !_ticker.isActive) {
      _ticker.start();
    } else if (!want && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tick = widget.tick;
    final height = widget.height;
    final scheme = Theme.of(context).colorScheme;
    final size = (height * 0.66).clamp(11.0, 30.0);
    final counted = scheme.onSurface.withValues(alpha: 0.50);
    final toCome = scheme.onSurface.withValues(alpha: 0.22);
    final now = scheme.primary;
    final pad = size * 0.45;
    // Room above the numbers for the breath's arc plus the dot itself.
    final headroom =
        widget.beatPosition == null ? 0.0 : size * (_breathLift + 0.4);

    final intro = tick.introProgress;
    if (intro != null) _hadIntro = true;
    final introShown = intro ?? (_hadIntro ? 1.0 : null);
    // During an intro the count proper hasn't begun: every number is still
    // to come, and the one on [tick.index] isn't being counted yet.
    Color colorFor(int i) => intro != null
        ? toCome
        : (i == tick.index ? now : (i < tick.index ? counted : toCome));

    final numberStyle = TextStyle(
      fontSize: size,
      height: 1.0,
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final labels = tick.labels;
    // One slot per beat, plus room to land in: past the last number by the
    // count's own length (lead rests can carry it beyond the next slot).
    final slot = size * 1.5;
    final slots = (tick.totalBeats > labels.length
            ? tick.totalBeats
            : labels.length.toDouble()) +
        1;

    final count = SizedBox(
      width: slot * slots,
      height: height + headroom,
      child: CustomPaint(
        painter: _CountPainter(
          labels: labels,
          colors: [for (var i = 0; i < labels.length; i++) colorFor(i)],
          barlines: countInBarlines(labels, tick.perBar),
          barColor: scheme.onSurface.withValues(alpha: 0.40),
          style: DefaultTextStyle.of(context).style.merge(numberStyle),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
          slot: slot,
          top: headroom,
          height: height,
        ),
        foregroundPainter: widget.beatPosition == null
            ? null
            : _DotPainter(
                beat: _beat,
                totalBeats: tick.totalBeats,
                labelCount: labels.length,
                slot: slot,
                restY: headroom + (height - size) / 2 - size * 0.18,
                fontSize: size,
                color: now,
              ),
      ),
    );

    // The count is right-aligned so the eye travels along it to the end of
    // the line — where the music starts. Scaled down, never clipped: a
    // count that loses its last numbers stops answering "how long have I got?".
    return Row(
      children: [
        if (introShown != null) ...[
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Intro…',
                  style: TextStyle(
                      fontSize: size * 0.7, height: 1.0, color: counted)),
              SizedBox(height: size * 0.2),
              SizedBox(
                width: size * 4,
                child: LinearProgressIndicator(
                  value: introShown,
                  minHeight: 2,
                  color: counted,
                  backgroundColor: toCome,
                ),
              ),
            ],
          ),
          SizedBox(width: pad),
        ],
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: count,
            ),
          ),
        ),
      ],
    );
  }
}

/// The count's numbers, each centred in its slot, and its bar lines.
class _CountPainter extends CustomPainter {
  _CountPainter({
    required this.labels,
    required this.colors,
    required this.barlines,
    required this.barColor,
    required this.style,
    required this.textScaler,
    required this.textDirection,
    required this.slot,
    required this.top,
    required this.height,
  });

  final List<int> labels;
  final List<Color> colors;
  final List<double> barlines;
  final Color barColor;
  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final double slot, top, height;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = top + height / 2;
    for (var i = 0; i < labels.length; i++) {
      final tp = TextPainter(
        text: TextSpan(
            text: '${labels[i]}', style: style.copyWith(color: colors[i])),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      tp.paint(canvas,
          Offset(slot * (i + 0.5) - tp.width / 2, midY - tp.height / 2));
      tp.dispose();
    }
    final fontSize = style.fontSize ?? 14;
    final bar = Paint()
      ..color = barColor
      ..strokeWidth = fontSize * 0.07;
    for (final b in barlines) {
      final x = slot * (b + 0.5);
      canvas.drawLine(Offset(x, midY - fontSize * 0.55),
          Offset(x, midY + fontSize * 0.55), bar);
    }
  }

  @override
  bool shouldRepaint(covariant _CountPainter old) =>
      !_listEquals(old.labels, labels) ||
      !_listEquals(old.colors, colors) ||
      !_listEquals(old.barlines, barlines) ||
      old.barColor != barColor ||
      old.style != style ||
      old.slot != slot ||
      old.top != top ||
      old.height != height;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _DotPainter extends CustomPainter {
  _DotPainter({
    required this.beat,
    required this.totalBeats,
    required this.labelCount,
    required this.slot,
    required this.restY,
    required this.fontSize,
    required this.color,
  }) : super(repaint: beat);

  final ValueNotifier<double> beat;
  final double totalBeats;
  final int labelCount;
  final double slot;
  final double restY;
  final double fontSize;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = countInDotOffset(beat.value, totalBeats, labelCount);
    canvas.drawCircle(Offset(slot * (p.x + 0.5), restY - p.lift * fontSize),
        fontSize * 0.14, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _DotPainter old) =>
      old.totalBeats != totalBeats ||
      old.labelCount != labelCount ||
      old.slot != slot ||
      old.restY != restY ||
      old.color != color ||
      old.fontSize != fontSize;
}

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
/// since the count began; see `PlaybackServiceBase.countInBeatPosition`).
///
/// [xs] holds the x of each counted number and, last, of the trailing `..` the
/// count runs into (the first note) — so `xs.length` is one more than the
/// number of labels. The dot rests on number `k` at beat `k` and hops, along a
/// parabola, to number `k+1` by beat `k+1`; the final hop lands on the
/// trailing `..` at [totalBeats], which is short of a whole beat when a
/// sub-beat pickup cuts the last count short.
///
/// Returns the x and the lift above the resting line, in font-size units — 0
/// exactly on every beat, which is the moment the dot "touches down".
({double x, double lift}) countInDotOffset(
    double beat, double totalBeats, List<double> xs) {
  if (xs.isEmpty) return (x: 0, lift: 0);
  final hops = xs.length - 1;
  if (hops == 0 || beat <= 0) return (x: xs.first, lift: 0);
  if (beat >= totalBeats) return (x: xs.last, lift: 0);
  final k = beat.floor().clamp(0, hops - 1);
  final isLast = k == hops - 1;
  final end = isLast ? totalBeats : (k + 1).toDouble();
  final span = end - k;
  final t = span <= 0 ? 1.0 : ((beat - k) / span).clamp(0.0, 1.0);
  final x = xs[k] + (xs[k + 1] - xs[k]) * t;
  final lift = 4 * t * (1 - t) * (isLast ? _breathLift : _hopLift);
  return (x: x, lift: lift);
}

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
///
/// With [beatPosition] given, a dot bounces from number to number in time (see
/// [countInDotOffset]), animated per frame rather than per playback tick. While
/// [CountInTick.introProgress] is set — a recording's intro is still playing —
/// the label shows a quiet "Intro" and its progress instead of the numbers.
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

    final decoration = BoxDecoration(
      // A pill, because the lane it lands in may already hold something — the
      // count-off is transient and has to stay readable over whatever it
      // covers for its two seconds. Fully opaque, not a wash.
      color: scheme.surface,
      borderRadius: BorderRadius.circular(pad),
    );

    final intro = tick.introProgress;
    if (intro != null) {
      return Container(
        height: height + headroom,
        padding: EdgeInsets.symmetric(horizontal: pad),
        decoration: decoration,
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Intro…',
                  style: TextStyle(
                      fontSize: size * 0.7, height: 1.0, color: counted)),
              SizedBox(height: size * 0.2),
              SizedBox(
                width: size * 4,
                child: LinearProgressIndicator(
                  value: intro,
                  minHeight: 2,
                  color: counted,
                  backgroundColor: toCome,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Color colorFor(int i) =>
        i == tick.index ? now : (i < tick.index ? counted : toCome);

    final baseStyle = TextStyle(
      fontSize: size,
      height: 1.0,
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // Character ranges of each number, and of the trailing `..`, so the dot
    // can find them in the laid-out text.
    final spans = <InlineSpan>[];
    final ranges = <(int, int)>[];
    var offset = 0;
    void add(String text, Color color, {bool mark = false}) {
      spans.add(TextSpan(text: text, style: TextStyle(color: color)));
      if (mark) ranges.add((offset, offset + text.length));
      offset += text.length;
    }

    for (var i = 0; i < tick.labels.length; i++) {
      if (i > 0) add(' .. ', toCome);
      add('${tick.labels[i]}', colorFor(i), mark: true);
    }
    add(' ', toCome);
    add('..', toCome, mark: true);
    final span = TextSpan(style: baseStyle, children: spans);

    final text = Text.rich(span,
        maxLines: 1, softWrap: false, overflow: TextOverflow.clip);

    if (widget.beatPosition == null) {
      return Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: pad),
        decoration: decoration,
        child: Align(widthFactor: 1, child: text),
      );
    }

    // Measure exactly as the Text widget will lay out.
    final painter = TextPainter(
      text: TextSpan(
          style: DefaultTextStyle.of(context).style.merge(baseStyle),
          children: spans),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final xs = <double>[
      for (final (start, end) in ranges)
        () {
          final boxes = painter.getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: end));
          if (boxes.isEmpty) return 0.0;
          return (boxes.first.left + boxes.last.right) / 2;
        }(),
    ];
    final textTop = headroom + (height - painter.height) / 2;
    painter.dispose();

    return Container(
      height: height + headroom,
      padding: EdgeInsets.symmetric(horizontal: pad),
      decoration: decoration,
      child: CustomPaint(
        foregroundPainter: _DotPainter(
          beat: _beat,
          totalBeats: tick.totalBeats,
          xs: xs,
          restY: textTop - size * 0.18,
          fontSize: size,
          color: now,
        ),
        child: Padding(
          padding: EdgeInsets.only(top: headroom),
          child: Align(widthFactor: 1, child: text),
        ),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter({
    required this.beat,
    required this.totalBeats,
    required this.xs,
    required this.restY,
    required this.fontSize,
    required this.color,
  }) : super(repaint: beat);

  final ValueNotifier<double> beat;
  final double totalBeats;
  final List<double> xs;
  final double restY;
  final double fontSize;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = countInDotOffset(beat.value, totalBeats, xs);
    canvas.drawCircle(Offset(p.x, restY - p.lift * fontSize), fontSize * 0.14,
        Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _DotPainter old) =>
      old.totalBeats != totalBeats ||
      old.restY != restY ||
      old.color != color ||
      old.fontSize != fontSize ||
      !_listEquals(old.xs, xs);

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

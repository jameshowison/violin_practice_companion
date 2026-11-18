import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../ui/adaptive/adaptive.dart';

/// Hold a bar, then slide: selects the bars from the held one to the one
/// under the finger, live, across lines, scrolling [controller] when the
/// finger rests near the top or bottom edge.
///
/// Hold first, deliberately — not a plain drag. The notation scrolls
/// vertically, and a drag that starts on it is the scroll's to win; a
/// sideways drag-to-select would take every slightly diagonal flick. Once the
/// hold is recognised (~500 ms, with a haptic tick) the long-press owns the
/// pointer, so the slide can go any direction and never scrolls by itself.
///
/// Wrap the whole scrolling view: the edge zones are this widget's own top
/// and bottom, less [bottomInset] (what sits over the view, the phone's play
/// tray). [measureAt] maps a GLOBAL position to a measure number, or null
/// over nothing; [measureTagAt] does that for views built of widgets (wrap
/// each bar in a [MeasureTag]).
class MeasureDragSelect extends StatefulWidget {
  const MeasureDragSelect({
    super.key,
    required this.controller,
    required this.measureAt,
    required this.onRange,
    required this.child,
    this.onDragging,
    this.bottomInset = 0,
    this.enabled = true,
  });

  final ScrollController controller;
  final int? Function(Offset global) measureAt;

  /// The range so far: the held bar and the bar under the finger, in drag
  /// order (not sorted). Called on the hold and whenever the bar changes.
  final void Function(int anchor, int current) onRange;

  /// True from the hold until the finger lifts.
  final ValueChanged<bool>? onDragging;
  final double bottomInset;
  final bool enabled;
  final Widget child;

  @override
  State<MeasureDragSelect> createState() => _MeasureDragSelectState();
}

/// How deep the edge zones reach into the view, as a fraction of its height.
const double measureDragEdgeZone = 0.12;

/// Edge auto-scroll speed at the very edge, in logical px per second.
const double measureDragMaxSpeed = 900;

class _MeasureDragSelectState extends State<MeasureDragSelect>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  int? _anchor;
  int? _current;
  Offset? _finger;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _start(LongPressStartDetails d) {
    final m = widget.measureAt(d.globalPosition);
    if (m == null) return;
    _anchor = m;
    _current = m;
    _finger = d.globalPosition;
    appSelectionHaptic();
    widget.onDragging?.call(true);
    widget.onRange(m, m);
  }

  void _move(LongPressMoveUpdateDetails d) {
    if (_anchor == null) return;
    _finger = d.globalPosition;
    _follow();
    if (_edgeSpeed() != 0 && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _end() {
    if (_ticker.isActive) _ticker.stop();
    if (_anchor == null) return;
    _anchor = null;
    _current = null;
    _finger = null;
    widget.onDragging?.call(false);
  }

  /// Re-reads the bar under the finger: after it moves, and after the
  /// content scrolls under a finger that stays put.
  void _follow() {
    final finger = _finger, anchor = _anchor;
    if (finger == null || anchor == null) return;
    final m = widget.measureAt(finger);
    if (m == null || m == _current) return;
    _current = m;
    widget.onRange(anchor, m);
  }

  /// Signed scroll speed for where the finger is: negative in the top zone,
  /// positive in the bottom one, growing towards the edge. 0 elsewhere.
  double _edgeSpeed() {
    final finger = _finger;
    final box = context.findRenderObject() as RenderBox?;
    if (finger == null || box == null || !box.hasSize) return 0;
    final y = box.globalToLocal(finger).dy;
    final h = box.size.height - widget.bottomInset;
    if (h <= 0) return 0;
    final zone = h * measureDragEdgeZone;
    if (y < zone) return -measureDragMaxSpeed * ((zone - y) / zone).clamp(0, 1);
    if (y > h - zone) {
      return measureDragMaxSpeed * ((y - (h - zone)) / zone).clamp(0, 1);
    }
    return 0;
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final speed = _edgeSpeed();
    final c = widget.controller;
    if (speed == 0 || !c.hasClients) {
      _ticker.stop();
      return;
    }
    final p = c.position;
    final to = (p.pixels + speed * dt).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (to != p.pixels) {
      c.jumpTo(to);
      _follow();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      onLongPressStart: _start,
      onLongPressMoveUpdate: _move,
      onLongPressEnd: (_) => _end(),
      onLongPressCancel: _end,
      child: widget.child,
    );
  }
}

/// Marks its child as bar [number] for [measureTagAt].
class MeasureTag extends StatelessWidget {
  const MeasureTag({super.key, required this.number, required this.child});

  final int number;
  final Widget child;

  @override
  Widget build(BuildContext context) => MetaData(
        metaData: _MeasureTagData(number),
        behavior: HitTestBehavior.opaque,
        child: child,
      );
}

class _MeasureTagData {
  const _MeasureTagData(this.number);
  final int number;
}

/// The bar a [MeasureTag] under [global] marks, hit-testing from [context]'s
/// render box down. Null between bars.
int? measureTagAt(BuildContext context, Offset global) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  final result = BoxHitTestResult();
  box.hitTest(result, position: box.globalToLocal(global));
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderMetaData && target.metaData is _MeasureTagData) {
      return (target.metaData as _MeasureTagData).number;
    }
  }
  return null;
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../models/section_palette.dart';
import '../services/midi_generator.dart';
import '../services/providers.dart';
import '../services/verovio_engraver.dart';

/// Native staff renderer: Verovio engraves (coordinates + per-element bboxes),
/// jovial_svg draws the SVG in Flutter's own pipeline, and native CustomPaint
/// overlays draw selection, section tints, flagged-measure markers, the
/// current-note highlight, and the playback cursor.
///
/// Drop-in for [StaffView] (`staff_view.dart`) — same public constructor — so
/// the call sites switch via `staffRendererProvider` with OSMD as fallback.
/// Unlike the OSMD WebView this is NOT a platform view, so Marionette/`simctl`
/// screenshots capture the notation.
class StaffViewVerovio extends ConsumerStatefulWidget {
  final String musicXml;
  final ValueNotifier<HighlightEvent?> highlightNotifier;

  /// Kept for API parity with [StaffView]; the native renderer has no bridge.
  final String bridgeAsset;

  final MeasureSelection? selection;
  final ValueChanged<int>? onMeasureTapped;
  final Set<int> flaggedMeasures;

  /// Model measure numbers in document (or unfolded performance) order; maps an
  /// engraved measure index ↔ our measure number, both directions.
  final List<int> measureNumbers;

  /// Parity with [StaffView]; the engraver always wraps systems to the page
  /// width, so there's no last-system justification to toggle.
  final bool stretchLastSystem;

  /// Per-section background washes, in engraved measure-index space.
  final List<SectionTintSpan> sectionTints;

  /// Minimap scroll-to-measure request (measure index + a sequence so identical
  /// requests still fire).
  final ({int index, int seq})? scrollNav;

  const StaffViewVerovio({
    super.key,
    required this.musicXml,
    required this.highlightNotifier,
    this.bridgeAsset = 'assets/osmd/osmd_bridge.html',
    this.selection,
    this.onMeasureTapped,
    this.flaggedMeasures = const {},
    this.measureNumbers = const [],
    this.stretchLastSystem = true,
    this.sectionTints = const [],
    this.scrollNav,
  });

  @override
  ConsumerState<StaffViewVerovio> createState() => _StaffViewVerovioState();
}

class _StaffViewVerovioState extends ConsumerState<StaffViewVerovio> {
  final _scrollController = ScrollController();

  EngravedScore? _score;
  ScalableImage? _image;
  String? _error;

  // The width the current [_score] was engraved for; re-engrave when the
  // available width crosses a bucket boundary (reflow on rotation/resize).
  double _engravedWidth = 0;
  int _engraveSeq = 0; // guards against out-of-order async results
  bool _engraving = false; // in-flight guard (avoid per-frame re-kicks)

  @override
  void initState() {
    super.initState();
    widget.highlightNotifier.addListener(_onHighlight);
  }

  @override
  void didUpdateWidget(StaffViewVerovio old) {
    super.didUpdateWidget(old);
    if (old.highlightNotifier != widget.highlightNotifier) {
      old.highlightNotifier.removeListener(_onHighlight);
      widget.highlightNotifier.addListener(_onHighlight);
      _onHighlight();
    }
    if (old.musicXml != widget.musicXml && _engravedWidth > 0) {
      _engrave(_engravedWidth);
    }
    if (widget.scrollNav != null && widget.scrollNav != old.scrollNav) {
      _scrollToMeasureIndex(widget.scrollNav!.index);
    }
  }

  @override
  void dispose() {
    widget.highlightNotifier.removeListener(_onHighlight);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _engrave(double widthPx) async {
    if (widthPx <= 0 || _engraving) return;
    _engraving = true;
    _engravedWidth = widthPx;
    final seq = ++_engraveSeq;
    try {
      final score = await VerovioEngraver.instance
          .engrave(widget.musicXml, widthPx: widthPx);
      if (!mounted || seq != _engraveSeq) return;
      // jovial parse is synchronous and fast (a few ms); currentColor resolves
      // Verovio's CSS stroke:currentColor on staff lines/stems/beams.
      final image = ScalableImage.fromSvgString(
        score.svg,
        currentColor: Colors.black,
        warnF: (_) {},
      );
      setState(() {
        _score = score;
        _image = image;
        _error = null;
      });
      _onHighlight(); // re-place the cursor on the fresh layout
    } catch (e) {
      if (mounted && seq == _engraveSeq) setState(() => _error = '$e');
    } finally {
      _engraving = false;
    }
  }

  void _onHighlight() {
    if (!mounted) return;
    // The overlay painter listens to highlightNotifier directly for repaint;
    // here we only need to drive page-turn autoscroll.
    final score = _score;
    final ev = widget.highlightNotifier.value;
    if (score == null || ev == null) return;
    final anchor = _anchorForEvent(score, ev);
    if (anchor != null) _autoScrollTo(anchor.rect);
  }

  NoteAnchor? _anchorForEvent(EngravedScore score, HighlightEvent ev) {
    // Map our measure number → engraved measure index. In folded mode numbers
    // are unique so this is exact; in unfolded/sectioned mode a repeated number
    // resolves to its first rendered copy (cursor sits on the first pass).
    final mi = widget.measureNumbers.indexOf(ev.measureNumber);
    if (mi < 0) return null;
    return score.noteAt(mi, ev.noteIndex);
  }

  // ── Scrolling ──────────────────────────────────────────────────────────

  double get _scale {
    final score = _score;
    if (score == null || _engravedWidth <= 0) return 1;
    return _engravedWidth / score.viewBox.width;
  }

  /// Page-turn autoscroll: keep the cursor comfortably in view. When it drops
  /// below the lower third (or above the top) of the viewport, animate so its
  /// system sits near the top — mirrors the OSMD bridge's scrollWithPageTurn.
  void _autoScrollTo(Rect rectVb) {
    if (!_scrollController.hasClients) return;
    final scale = _scale;
    final top = rectVb.top * scale;
    final bottom = rectVb.bottom * scale;
    final viewport = _scrollController.position.viewportDimension;
    final offset = _scrollController.offset;
    final visibleTop = offset;
    final visibleBottom = offset + viewport;
    if (bottom <= visibleBottom - 8 && top >= visibleTop + 8) return;
    // Anchor the cursor's system ~25% down the viewport.
    var target = top - viewport * 0.25;
    target = target.clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  void _scrollToMeasureIndex(int index) {
    final score = _score;
    if (score == null || !_scrollController.hasClients) return;
    final m = score.measureAt(index);
    if (m == null) return;
    final target = (m.rect.top * _scale - 12)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  // ── Taps ───────────────────────────────────────────────────────────────

  void _onTapDown(Offset local) {
    final score = _score;
    if (score == null) return;
    final scale = _scale;
    final p = Offset(local.dx / scale, local.dy / scale);
    // Measure tap (existing select-on-notation behavior).
    for (final m in score.measures) {
      if (m.rect.contains(p)) {
        if (m.index >= 0 && m.index < widget.measureNumbers.length) {
          widget.onMeasureTapped?.call(widget.measureNumbers[m.index]);
        }
        return;
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text('Staff view error: $_error', textAlign: TextAlign.center),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Engrave once a real width is known, and re-engrave (reflow) when the
        // width crosses a bucket boundary. Scheduled post-frame so we don't
        // setState during layout.
        final needsEngrave =
            width > 0 && (_score == null || _bucket(width) != _bucket(_engravedWidth));
        if (needsEngrave) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && (_score == null || _bucket(width) != _bucket(_engravedWidth))) {
              _engrave(width);
            }
          });
        }
        final score = _score;
        final image = _image;
        if (score == null || image == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final scale = width / score.viewBox.width;
        final renderH = score.viewBox.height * scale;
        final theme = Theme.of(context);
        return SingleChildScrollView(
          controller: _scrollController,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _onTapDown(d.localPosition),
            child: SizedBox(
              width: width,
              height: renderH,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _UnderlayPainter(
                        score: score,
                        scale: scale,
                        sectionTints: widget.sectionTints,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: ScalableImageWidget(si: image, fit: BoxFit.fitWidth),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _OverlayPainter(
                          repaint: widget.highlightNotifier,
                          score: score,
                          scale: scale,
                          measureNumbers: widget.measureNumbers,
                          selection: widget.selection,
                          flaggedMeasures: widget.flaggedMeasures,
                          highlight: widget.highlightNotifier,
                          primary: theme.colorScheme.primary,
                          flagColor: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static int _bucket(double w) => (w / 48).round();
}

/// Drawn UNDER the notation: per-section background washes.
class _UnderlayPainter extends CustomPainter {
  _UnderlayPainter({
    required this.score,
    required this.scale,
    required this.sectionTints,
  });

  final EngravedScore score;
  final double scale;
  final List<SectionTintSpan> sectionTints;

  @override
  void paint(Canvas canvas, Size size) {
    for (final span in sectionTints) {
      final rect = _spanRect(span.start, span.end);
      if (rect == null) continue;
      final color = _parseHex(span.color).withValues(alpha: 0.10);
      canvas.drawRect(rect, Paint()..color = color);
    }
  }

  Rect? _spanRect(int startIndex, int endIndex) {
    Rect? acc;
    for (var i = startIndex; i <= endIndex; i++) {
      final m = score.measureAt(i);
      if (m == null) continue;
      final r = _scaled(m.rect);
      acc = acc == null ? r : acc.expandToInclude(r);
    }
    return acc;
  }

  Rect _scaled(Rect r) =>
      Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale);

  static Color _parseHex(String hex) {
    final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x888888;
    return Color(0xFF000000 | v);
  }

  @override
  bool shouldRepaint(_UnderlayPainter old) =>
      old.score != score ||
      old.scale != scale ||
      old.sectionTints != sectionTints;
}

/// Drawn OVER the notation: selection range, flagged markers, current-note
/// highlight, and the playback cursor. Repaints when [highlight] ticks.
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required Listenable repaint,
    required this.score,
    required this.scale,
    required this.measureNumbers,
    required this.selection,
    required this.flaggedMeasures,
    required this.highlight,
    required this.primary,
    required this.flagColor,
  }) : super(repaint: repaint);

  final EngravedScore score;
  final double scale;
  final List<int> measureNumbers;
  final MeasureSelection? selection;
  final Set<int> flaggedMeasures;
  final ValueNotifier<HighlightEvent?> highlight;
  final Color primary;
  final Color flagColor;

  Rect _scaled(Rect r) =>
      Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale);

  int _indexOf(int measureNumber) => measureNumbers.indexOf(measureNumber);

  @override
  void paint(Canvas canvas, Size size) {
    // Selection range fill (measure numbers → indices, mirroring the OSMD path).
    final sel = selection;
    if (sel != null) {
      final start = _indexOf(sel.startMeasure);
      final end = _indexOf(sel.endMeasure);
      if (start >= 0 && end >= 0) {
        final fill = Paint()..color = primary.withValues(alpha: 0.16);
        for (var i = start; i <= end; i++) {
          final m = score.measureAt(i);
          if (m != null) canvas.drawRect(_scaled(m.rect), fill);
        }
      }
    }

    // Flagged-measure markers: a small warning triangle at the measure's top-left.
    for (final number in flaggedMeasures) {
      final i = _indexOf(number);
      final m = score.measureAt(i);
      if (m == null) continue;
      _drawFlag(canvas, _scaled(m.rect));
    }

    // Current-note highlight + playback cursor.
    final ev = highlight.value;
    if (ev != null) {
      final mi = _indexOf(ev.measureNumber);
      final anchor = mi < 0 ? null : score.noteAt(mi, ev.noteIndex);
      if (anchor != null) {
        final r = _scaled(anchor.rect).inflate(3);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(3)),
          Paint()..color = primary.withValues(alpha: 0.30),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(3)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = primary,
        );
      }
    }
  }

  void _drawFlag(Canvas canvas, Rect measure) {
    const s = 9.0;
    final x = measure.left + 2;
    final y = measure.top + 2;
    final path = Path()
      ..moveTo(x, y + s)
      ..lineTo(x + s / 2, y)
      ..lineTo(x + s, y + s)
      ..close();
    canvas.drawPath(path, Paint()..color = flagColor.withValues(alpha: 0.9));
    // Exclamation dot.
    canvas.drawCircle(
        Offset(x + s / 2, y + s - 2), 0.8, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.score != score ||
      old.scale != scale ||
      old.selection != selection ||
      old.flaggedMeasures != flaggedMeasures ||
      old.measureNumbers != measureNumbers ||
      old.primary != primary;
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../models/section_palette.dart';
import '../services/midi_generator.dart';
import '../services/providers.dart';
import '../services/staff_zoom.dart';
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

  /// Per-section background washes, with note-level edges (engraved-index space).
  final List<SectionTintRegion> sectionTints;

  /// Minimap scroll-to-measure request (measure index + a sequence so identical
  /// requests still fire).
  final ({int index, int seq})? scrollNav;

  /// Tab view: this score has a second (tab) staff. Excludes its notes from the
  /// anchors and keeps the per-system "T-A-B" clef.
  final bool tabMode;

  /// Tab view (fingering mode): fingering labels, in document order, swapped in
  /// for Verovio's native fret numbers. Null → fret mode (native numbers stay).
  final List<String>? tabFingerLabels;

  /// Whether the user's [measuresPerLineProvider] override applies. False for
  /// incidental previews (the measure editor, the note palette) that show a bar
  /// or two and should always just auto-fit their box — a whole-piece zoom of
  /// "4 measures per line" would render a single-measure preview at a quarter
  /// size.
  final bool zoomable;

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
    this.tabMode = false,
    this.tabFingerLabels,
    this.zoomable = true,
  });

  @override
  ConsumerState<StaffViewVerovio> createState() => _StaffViewVerovioState();
}

/// One engrave request: the box to fill, the measures-per-line target (null =
/// auto, resolved against [viewportHeightPx] once calibrated), and the vertical
/// staff spacing.
typedef _EngraveRequest = ({
  double widthPx,
  double viewportHeightPx,
  int? target,
  double staffSpacing,
});

class _StaffViewVerovioState extends ConsumerState<StaffViewVerovio> {
  final _scrollController = ScrollController();

  EngravedScore? _score;
  ScalableImage? _image;
  String? _error;

  // The width the current [_score] was engraved for; re-engrave when the
  // available width crosses a bucket boundary (reflow on rotation/resize).
  // Assigned only after a successful engrave, so it always describes [_score].
  double _engravedWidth = 0;

  /// The measures-per-line target the current [_score] satisfies — the raw
  /// request value, so null means "this score came from auto". Compared against
  /// the live provider to decide whether a re-engrave is needed.
  int? _engravedTarget;

  /// The staff spacing the current [_score] was engraved with; a change means a
  /// re-engrave (and a re-calibration, since it moves the system height).
  double? _engravedSpacing;

  /// The width the last build laid out at — the single denominator for the
  /// viewBox→screen scale, shared by the painters, hit testing and autoscroll.
  double _layoutWidth = 0;

  /// Calibration for [_calibratedFor] (the XML/variant it was measured on):
  /// average measure width in MEI units (scale- and width-invariant), average
  /// system height in pixels **at [staffScaleProbe]** (not invariant — callers
  /// convert by the scale ratio), and the measure count. See `staff_zoom.dart`.
  String? _calibratedFor;
  double _unitsPerMeasure = 0;
  double _systemHeightPx = 0; // measured at [staffScaleProbe]
  int _measureCount = 0;

  int _engraveSeq = 0; // discards out-of-order async results
  bool _engraving = false;
  _EngraveRequest? _pending; // latest-wins queue

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
    // New content invalidates both the render and the calibration; clearing
    // _engravedWidth makes the build-time check below kick a fresh request, so
    // there's only one place that decides to engrave.
    if (old.musicXml != widget.musicXml ||
        old.tabMode != widget.tabMode ||
        !listEquals(old.tabFingerLabels, widget.tabFingerLabels)) {
      _engravedWidth = 0;
      _calibratedFor = null;
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

  /// Key the calibration is valid for. Everything that changes the engraved
  /// geometry counts: the tab variant (a second staff changes the system height)
  /// and the staff spacing (which changes it directly, and so changes what the
  /// auto-fit rule can afford).
  String _calibrationKeyFor(double staffSpacing) =>
      '${widget.musicXml.hashCode}|${widget.tabMode}|$staffSpacing';

  // ── Engrave queue ──────────────────────────────────────────────────────
  //
  // Latest-wins: a new request replaces any queued one, and the in-flight run
  // picks up whatever is newest when it finishes. A plain "drop while busy"
  // guard would discard the FINAL value of a slider drag and leave a
  // permanently stale render.

  void _request(_EngraveRequest req) {
    if (req.widthPx <= 0) return;
    _pending = req;
    if (_engraving) return;
    _drain();
  }

  Future<void> _drain() async {
    _engraving = true;
    try {
      while (mounted && _pending != null) {
        final req = _pending!;
        _pending = null;
        await _engrave(req);
      }
    } finally {
      _engraving = false;
    }
  }

  Future<void> _engrave(_EngraveRequest req) async {
    final seq = ++_engraveSeq;
    try {
      // 1. Calibrate. unitsPerMeasure is a property of the piece, invariant in
      //    both scale and width, so one probe engrave per score serves every
      //    later zoom level. The probe uses the pre-zoom option set, so an
      //    un-zoomed piece reuses the cache entry it always had.
      EngravedScore? probe;
      if (_calibratedFor != _calibrationKeyFor(req.staffSpacing)) {
        probe = await _engraveAt(req.widthPx, staffScaleProbe,
            staffSpacing: req.staffSpacing);
        if (!mounted || seq != _engraveSeq) return;
        _unitsPerMeasure = unitsPerMeasureFrom(
          pageWidthUnits: probe.pageWidthUnits,
          measuresPerLine: measuresPerLineOf(probe.measureLine),
        );
        _systemHeightPx = probe.systemHeightViewBox;
        _measureCount = probe.measures.length;
        _calibratedFor = _calibrationKeyFor(req.staffSpacing);
      }

      // 2. Resolve the target and solve for Verovio's scale.
      final target = req.target ??
          autoMeasuresPerLine(
            widthPx: req.widthPx,
            viewportHeightPx: req.viewportHeightPx,
            unitsPerMeasure: _unitsPerMeasure,
            systemHeightPx: _systemHeightPx,
            measureCount: _measureCount,
          );
      final scale = scaleFor(
        widthPx: req.widthPx,
        unitsPerMeasure: _unitsPerMeasure,
        n: target,
      );

      // 3. Engrave for real — unless the probe already produced exactly this
      //    layout. Every option must match, not just the scale: reusing a probe
      //    whose page was shorter would silently clip a long score's tail (only
      //    page 1 is ever rendered), and its bar numbering would be off-interval.
      final reusable = probe != null &&
          (scale - staffScaleProbe).abs() < 0.05 &&
          _pageHeightFor(target) == _probePageHeightUnits &&
          target == _probeMnumInterval;
      final score = reusable
          ? probe
          : await _engraveAt(req.widthPx, scale,
              measuresPerLine: target, staffSpacing: req.staffSpacing);
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
        _engravedWidth = req.widthPx;
        _engravedTarget = req.target;
        _engravedSpacing = req.staffSpacing;
      });
      // Report what Verovio actually did — its break points are musical, so a
      // dense bar can land one short of the target. Drives the slider readout.
      // Only the whole-piece views speak for it; a one-bar preview would
      // otherwise overwrite the readout with its own count.
      if (widget.zoomable) {
        ref.read(effectiveMeasuresPerLineProvider.notifier).state =
            measuresPerLineOf(score.measureLine);
      }
      _onHighlight(); // re-place the cursor on the fresh layout
    } catch (e) {
      if (mounted && seq == _engraveSeq) setState(() => _error = '$e');
    }
  }

  // The calibration probe's option set is deliberately the pre-zoom one, so an
  // un-zoomed piece reuses the engraver cache entry it always had.
  static const _probePageHeightUnits = 60000;
  static const _probeMnumInterval = 4;

  /// Page height for a [measuresPerLine] layout. Only page 1 is ever rendered,
  /// so the page must hold every system — and zooming in multiplies them.
  int _pageHeightFor(int measuresPerLine) => pageHeightUnitsFor(
        measureCount: _measureCount,
        measuresPerLine: measuresPerLine,
        systemHeightPx: _systemHeightPx,
      );

  Future<EngravedScore> _engraveAt(double widthPx, double scale,
      {int? measuresPerLine, required double staffSpacing}) {
    return VerovioEngraver.instance.engrave(
      widget.musicXml,
      widthPx: widthPx,
      scale: scale,
      spacingSystem: verovioSpacingSystemFor(staffSpacing),
      pageHeightUnits: measuresPerLine == null
          ? _probePageHeightUnits
          : _pageHeightFor(measuresPerLine),
      // A bar number on every system beats a fixed every-4-bars once the line
      // length is the thing being adjusted.
      mnumInterval: measuresPerLine ?? _probeMnumInterval,
      tabMode: widget.tabMode,
      tabFingerLabels: widget.tabFingerLabels,
      stripRepeatClefs: !widget.tabMode,
    );
  }

  void _onHighlight() {
    if (!mounted) return;
    // The overlay painter listens to highlightNotifier directly for repaint;
    // here we only need to drive page-turn autoscroll.
    final score = _score;
    final ev = widget.highlightNotifier.value;
    if (score == null || ev == null) return;
    final anchor = _anchorForEvent(score, ev);
    if (anchor == null) return;
    var rect = anchor.rect;
    if (widget.tabMode) {
      // The cursor sits on the melody note, but the tab staff is drawn below
      // it. Extend the scroll rect down to the measure's full height (which
      // spans both staves) so autoscroll keeps the tab — not just the staff
      // note — in view.
      final m = score.measureAt(anchor.measureIndex);
      if (m != null) {
        rect = Rect.fromLTRB(rect.left, rect.top, rect.right, m.rect.bottom);
      }
    }
    _autoScrollTo(rect);
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

  /// viewBox → screen scale. Derived from the width the widget is actually laid
  /// out at (not the width the score was engraved for): after a zoom change the
  /// two differ for a frame, and taps/overlays must follow what is on screen.
  double get _scale {
    final score = _score;
    if (score == null || _layoutWidth <= 0 || score.viewBox.width <= 0) return 1;
    return _layoutWidth / score.viewBox.width;
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
    // Null = auto-fit. The previews (measure editor, palette) opt out so a
    // whole-piece zoom doesn't shrink their single bar.
    final zoom = ref.watch(measuresPerLineProvider);
    final target = widget.zoomable ? zoom.value : null;
    // Hold off the first engrave until the piece's saved zoom has been read,
    // otherwise every piece with an override engraves the auto default first and
    // throws it away. Previews don't read the setting, so they never wait.
    final waitingForZoom = widget.zoomable && !zoom.restored;
    // Vertical gap between systems. Was wired only to the OSMD fallback, so it
    // did nothing under this (default) renderer until now.
    final staffSpacing = ref.watch(staffSpacingProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // The LayoutBuilder sits OUTSIDE the SingleChildScrollView, so maxHeight
        // is the real viewport height — what the auto-fit rule budgets against.
        final viewportHeight = constraints.maxHeight;
        _layoutWidth = width;
        // Engrave once a real width is known; re-engrave (reflow) when the width
        // crosses a bucket boundary or the target changes. Height is read at
        // engrave time but deliberately does NOT trigger a reflow: it shifts
        // whenever the compact bottom tray slides, and re-engraving the score
        // under a moving tray would be jarring.
        bool stale() =>
            _score == null ||
            _bucket(width) != _bucket(_engravedWidth) ||
            target != _engravedTarget ||
            staffSpacing != _engravedSpacing;
        if (width > 0 && !waitingForZoom && stale()) {
          // Scheduled post-frame so we don't setState during layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !waitingForZoom && stale()) {
              _request((
                widthPx: width,
                viewportHeightPx: viewportHeight,
                target: target,
                staffSpacing: staffSpacing,
              ));
            }
          });
        }
        final score = _score;
        final image = _image;
        if (score == null || image == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final scale = _scale;
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

/// Drawn UNDER the notation: per-section background washes. Each region paints
/// one rect per system line it spans (a section can wrap several lines), clipped
/// to the section's first/last note so a mid-measure section start/end colors
/// only its own notes.
///
/// The vertical extent of each rect is a UNIFORM band per system line — the
/// union of every measure's bbox on that line — not each measure's own height.
/// That keeps the wash a clean rectangle (no stepping as notes go high/low, and
/// no white gaps between measures within a line).
class _UnderlayPainter extends CustomPainter {
  _UnderlayPainter({
    required this.score,
    required this.scale,
    required this.sectionTints,
  });

  final EngravedScore score;
  final double scale;
  final List<SectionTintRegion> sectionTints;

  @override
  void paint(Canvas canvas, Size size) {
    if (sectionTints.isEmpty) return;
    for (final region in sectionTints) {
      final color = _parseHex(region.color).withValues(alpha: 0.10);
      for (final rect in _regionRowRects(region)) {
        canvas.drawRect(rect, Paint()..color = color);
      }
    }
  }

  /// Drawn (viewBox→screen scaled) rects for [r], one per system line. Measures
  /// are unioned horizontally within a line; the line's TILED band (from the
  /// engraving) sets the height so adjacent lines neither overlap nor gap; the
  /// first measure's left and a partial last measure's right are clipped to
  /// notes (mid-measure section edges).
  List<Rect> _regionRowRects(SectionTintRegion r) {
    // Last measure index that gets any wash: a whole-measure end (-1) or a
    // mid-measure end (endNote>0) includes endMeasureIndex; endNote==0 stops at
    // the measure before it.
    final lastIdx = r.endNote == -1
        ? r.endMeasureIndex
        : (r.endNote > 0 ? r.endMeasureIndex : r.endMeasureIndex - 1);
    if (lastIdx < r.startMeasureIndex) return const [];

    final byLine = <int, ({double left, double right, double top, double bottom})>{};
    for (var i = r.startMeasureIndex; i <= lastIdx; i++) {
      final m = score.measureAt(i);
      final band = score.bandForMeasure(i);
      if (m == null || band == null) continue;
      var left = m.rect.left;
      var right = m.rect.right;
      if (i == r.startMeasureIndex && r.startNote > 0) {
        final n = score.noteAt(i, r.startNote);
        if (n != null) left = n.rect.left;
      }
      if (r.endNote > 0 && i == r.endMeasureIndex) {
        final n = score.noteAt(i, r.endNote);
        if (n != null) right = n.rect.left;
      }
      if (right <= left) continue;
      final line = score.lineOfMeasure(i);
      final cur = byLine[line];
      byLine[line] = cur == null
          ? (left: left, right: right, top: band.top, bottom: band.bottom)
          : (
              left: left < cur.left ? left : cur.left,
              right: right > cur.right ? right : cur.right,
              top: cur.top,
              bottom: cur.bottom,
            );
    }
    return [
      for (final s in byLine.values)
        _scaled(Rect.fromLTRB(s.left, s.top, s.right, s.bottom))
    ];
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

  /// Scaled rects covering measure indices [startIdx]..[endIdx], one per system
  /// line: measures unioned horizontally, the line's tiled band as the height.
  List<Rect> _measureBandRects(int startIdx, int endIdx) {
    final byLine = <int, ({double left, double right, double top, double bottom})>{};
    for (var i = startIdx; i <= endIdx; i++) {
      final m = score.measureAt(i);
      final band = score.bandForMeasure(i);
      if (m == null || band == null) continue;
      final line = score.lineOfMeasure(i);
      final cur = byLine[line];
      byLine[line] = cur == null
          ? (left: m.rect.left, right: m.rect.right, top: band.top, bottom: band.bottom)
          : (
              left: m.rect.left < cur.left ? m.rect.left : cur.left,
              right: m.rect.right > cur.right ? m.rect.right : cur.right,
              top: cur.top,
              bottom: cur.bottom,
            );
    }
    return [
      for (final s in byLine.values)
        _scaled(Rect.fromLTRB(s.left, s.top, s.right, s.bottom))
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Selection range fill (measure numbers → indices, mirroring the OSMD path).
    // Uses the same tiled per-line bands as the section wash so the highlight is
    // a clean even band rather than stepping with note heights.
    final sel = selection;
    if (sel != null) {
      final start = _indexOf(sel.startMeasure);
      final end = _indexOf(sel.endMeasure);
      if (start >= 0 && end >= 0) {
        final fill = Paint()..color = primary.withValues(alpha: 0.16);
        for (final rect in _measureBandRects(start, end)) {
          canvas.drawRect(rect, fill);
        }
      }
    }

    // Flagged-measure markers: a small warning triangle at the measure's top-left.
    for (final number in flaggedMeasures) {
      final i = _indexOf(number);
      final m = score.measureAt(i);
      if (m == null) continue;
      _drawFlag(canvas, _scaled(m.rect), (_bandPx(i) * 0.13).clamp(7.0, 26.0));
    }

    // Current-note highlight + playback cursor.
    final ev = highlight.value;
    if (ev != null) {
      final mi = _indexOf(ev.measureNumber);
      final anchor = mi < 0 ? null : score.noteAt(mi, ev.noteIndex);
      if (anchor != null) {
        final pad = (_bandPx(mi) * 0.035).clamp(2.0, 9.0);
        final r = _scaled(anchor.rect).inflate(pad);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, Radius.circular(pad)),
          Paint()..color = primary.withValues(alpha: 0.30),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, Radius.circular(pad)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (pad * 0.7).clamp(1.5, 4.0)
            ..color = primary,
        );
      }
    }
  }

  /// Screen-space height of the system band holding [measureIndex] — the yardstick
  /// for decoration sizes, so the flag and cursor outline stay proportionate to
  /// the notes at any zoom (`scale` itself is ~1 at every zoom level, because the
  /// score is always engraved to the render width).
  double _bandPx(int measureIndex) {
    final band = score.bandForMeasure(measureIndex);
    if (band == null) return 48 * scale;
    return (band.bottom - band.top) * scale;
  }

  void _drawFlag(Canvas canvas, Rect measure, double s) {
    final x = measure.left + s * 0.22;
    final y = measure.top + s * 0.22;
    final path = Path()
      ..moveTo(x, y + s)
      ..lineTo(x + s / 2, y)
      ..lineTo(x + s, y + s)
      ..close();
    canvas.drawPath(path, Paint()..color = flagColor.withValues(alpha: 0.9));
    // Exclamation dot.
    canvas.drawCircle(Offset(x + s / 2, y + s - s * 0.22), s * 0.09,
        Paint()..color = Colors.white);
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

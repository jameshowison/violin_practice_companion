import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../models/chord_palette.dart';
import '../models/count_in.dart';
import '../models/section_palette.dart';
import '../models/violin_string_palette.dart';
import '../services/fingering_annotation_builder.dart';
import '../services/midi_generator.dart';
import '../services/providers.dart';
import '../services/staff_zoom.dart';
import '../services/verovio_engraver.dart';
import 'chord_swatch.dart';
import 'count_in_label.dart';

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

  /// The count-off in progress, drawn as `1 .. 2 .. 3 ..` just above the time
  /// signature. Null for the incidental previews (the measure editor, the note
  /// palette), which have no playback of their own.
  final ValueNotifier<CountInTick?>? countInNotifier;

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

  /// Chord runs, drawn as labelled colored bars in a lane above each system. This
  /// renderer owns the chord label entirely — the callers strip `<harmony>` from
  /// the XML so Verovio engraves no `<harm>` text to duplicate it.
  final List<ChordRunRegion> chordRuns;

  /// Fingering labels, drawn as coloured chips in a channel between the notes and
  /// the chord lane. As with the chords, this renderer owns them entirely — the
  /// callers strip `<fingering>` from the XML so Verovio engraves none.
  ///
  /// Changing this list re-paints but never re-engraves, so the density slider
  /// and the colour toggle are instant.
  final List<FingeringAnnotation> fingeringAnnotations;

  /// How the fingering channel expresses the string: coloured chips, a coloured
  /// rule under near-black numbers, or not at all.
  ///
  /// The counterpart to the label: while a colour is carrying the string the
  /// label drops the G/D/A/E letter, and with [StringColourStyle.off] the letter
  /// comes back. Showing both would say the same thing twice.
  final StringColourStyle stringColourStyle;

  /// Unbroken spans on one string, for [StringColourStyle.underline]. Spans every
  /// note, not just the labelled ones — see [stringRunRegions].
  final List<StringRunRegion> stringRuns;

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
    this.countInNotifier,
    this.bridgeAsset = 'assets/osmd/osmd_bridge.html',
    this.selection,
    this.onMeasureTapped,
    this.flaggedMeasures = const {},
    this.measureNumbers = const [],
    this.stretchLastSystem = true,
    this.sectionTints = const [],
    this.chordRuns = const [],
    this.fingeringAnnotations = const [],
    this.stringColourStyle = StringColourStyle.chips,
    this.stringRuns = const [],
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
/// gap between systems.
///
/// [shortestSidePx] is the screen's shortest side, which fixes the device class
/// and so the auto-fit's minimum physical note size (`minStaffScaleFor`). It gets
/// no term of its own in the staleness check: being orientation-invariant, it can
/// only change on a genuine screen change (rotation to a different window size,
/// an iPad split-view resize), and every one of those moves [widthPx] far more
/// than the one width bucket that already triggers a re-engrave.
///
/// [spacingUnits] is the staff-spacing preference resolved to Verovio units (see
/// `verovioSpacingSystemFor`). Carrying the resolved value rather than the raw
/// preference is what lets the staleness check and the calibration key collapse
/// every preference value that rounds to the same gap into one engrave, instead
/// of re-probing on each tick of a slider drag that cannot change the layout.
///
/// The annotation reserve is NOT in here, in either of its halves. It is derived
/// from the probe inside [_engrave] and is a function of the preference and the
/// xml, both of which are already keyed — so adding it would key the calibration
/// on something the calibration itself produces.
typedef _EngraveRequest = ({
  double widthPx,
  double viewportHeightPx,
  double shortestSidePx,
  int? target,
  int spacingUnits,
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

  /// The effective `spacingSystem` the current [_score] was engraved with; a
  /// change means a re-engrave (and a re-calibration, since it moves the system
  /// height).
  int? _engravedSpacingUnits;

  /// The width the last build laid out at — the single denominator for the
  /// viewBox→screen scale, shared by the painters, hit testing and autoscroll.
  double _layoutWidth = 0;

  /// The height the last build drew the page at (`viewBox.height × _scale`) —
  /// the counterpart to [_layoutWidth]. Only the pinch needs it, to turn a focal
  /// point into a [Transform] alignment: the gesture's box is the page, which is
  /// taller than this widget whenever the score scrolls.
  double _renderHeight = 0;

  /// Calibration for [_calibratedFor] (the XML/variant it was measured on):
  /// average measure width in MEI units (scale- and width-invariant), average
  /// system height in pixels **at [staffScaleProbe]** (not invariant — callers
  /// convert by the scale ratio), and the measure count. See `staff_zoom.dart`.
  String? _calibratedFor;

  /// Average measure width in MEI units — a running **upper bound** on Verovio's
  /// natural minimum, tightened by [_tightenCalibration] after every engrave.
  ///
  /// One engrave can only ever say "N measures DID fit in W units", so the
  /// estimate `W / N` is inflated by however much justification stretched that
  /// line: up to half a measure, which at the probe's own 2-measures-per-line is
  /// 25%. Measured on Old Joe Clark in portrait, the probe said 447.5 while the
  /// score really packed 4 bars into 1410 units (352) — so the solve asked for 3
  /// bars a line, got 4, and left the notes a quarter smaller than the screen
  /// could have shown. [staffFitSlack] absorbs a few percent of this; it cannot
  /// absorb 27%.
  ///
  /// Taking the minimum over every engrave seen fixes it with no search: each
  /// observation is a hard fact, the bound falls monotonically, and one
  /// corrective engrave is enough in practice.
  double _unitsPerMeasure = 0;
  double _systemHeightPx = 0; // measured at [staffScaleProbe]
  int _measureCount = 0;

  /// Corrective re-engraves spent on the current calibration. Bounded purely as
  /// a backstop: the bound must fall by a real margin to trigger one, so this
  /// should never reach its limit.
  int _refinements = 0;

  /// The reserve derived from the calibration probe — extra `spacingSystem` and
  /// `pageMarginTop` units for the annotation rows, or zeros when this score's
  /// own layout already has room. Derived, not preferred, so it lives beside the
  /// calibration it comes from and is refreshed with it.
  int _reserveSpacingUnits = 0;
  int _reservePageMarginUnits = 0;

  int _engraveSeq = 0; // discards out-of-order async results
  bool _engraving = false;
  _EngraveRequest? _pending; // latest-wins queue

  // ── Pinch ──────────────────────────────────────────────────────────────
  //
  // Zoom is an integer measures-per-line, and every change of it costs a full
  // re-engrave. So the pinch does NOT drive the target continuously: it scales
  // the already-rendered page with a Transform for as long as the fingers are
  // down, and commits exactly one new target when they lift. One engrave per
  // gesture, at 60fps throughout.
  //
  // The honest cost is that the preview does not reflow — measures don't move
  // between systems until the release — so the layout visibly settles at the
  // end. [pinchScaleLimits] at least keeps the *size* promise truthful by
  // refusing to grow the picture past what the clamped target can deliver.

  /// Live pinch factor applied to the rendered page; 1 at rest.
  double _pinchScale = 1;

  /// Measures-per-line the current pinch started from, and the bounds the
  /// preview may be driven between. Captured once at [_onScaleStart] so the
  /// gesture is measured against a fixed origin rather than drifting.
  int _pinchFrom = measuresPerLineMin;
  ({double min, double max}) _pinchLimits = (min: 1, max: 1);

  /// Where the transform is anchored — the point between the fingers, so the
  /// music under them stays put instead of sliding off.
  Alignment _pinchAnchor = Alignment.center;

  void _onScaleStart(ScaleStartDetails d) {
    // Same expression the drawer's slider parks its thumb on: the explicit
    // override if there is one, else what the renderer actually achieved.
    _pinchFrom =
        (ref.read(measuresPerLineProvider).value ??
                ref.read(effectiveMeasuresPerLineProvider) ??
                measuresPerLineForWidth(_layoutWidth))
            .clamp(measuresPerLineMin, measuresPerLineMax);
    _pinchLimits = pinchScaleLimits(_pinchFrom);
    _pinchAnchor = (_layoutWidth <= 0 || _renderHeight <= 0)
        ? Alignment.center
        : Alignment(
            (d.localFocalPoint.dx / _layoutWidth) * 2 - 1,
            (d.localFocalPoint.dy / _renderHeight) * 2 - 1,
          );
    setState(() => _pinchScale = 1);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    // One finger is a scroll, not a zoom — see [_PinchOnlyScaleRecognizer].
    if (d.pointerCount < 2) return;
    final next = d.scale.clamp(_pinchLimits.min, _pinchLimits.max);
    if (next == _pinchScale) return;
    setState(() => _pinchScale = next);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final target = pinchTargetMeasuresPerLine(
      from: _pinchFrom,
      scale: _pinchScale,
    );
    final current = ref.read(measuresPerLineProvider).value;
    if (target == current) {
      // Nothing to engrave, so nothing will come along to clear the preview.
      setState(() => _pinchScale = 1);
      return;
    }
    // Hold the preview at the size the new target will render at — cleared when
    // the fresh score is published (see [_engrave]). Dropping it at the release
    // instead would snap back to the old size for the length of the engrave and
    // then jump.
    setState(() => _pinchScale = _pinchFrom / target);
    ref.read(measuresPerLineProvider.notifier).commit(target);
  }

  /// Whether the score being engraved carries the annotations the app draws its
  /// own rows on, and so needs the room reserved from Verovio. See
  /// [scoreReservesAnnotationRoom].
  ///
  /// Cached rather than asked per build: it is a scan of the whole MusicXML and
  /// `build` runs on every highlight tick, but it can only change when
  /// [StaffViewVerovio.musicXml] does, which is a widget property.
  late bool _reservesAnnotationRoom;

  @override
  void initState() {
    super.initState();
    _reservesAnnotationRoom = scoreReservesAnnotationRoom(widget.musicXml);
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
    // The lane count belongs here and not in the build-time `stale()` check for
    // the same reason tabMode does: it's a widget property, so this is the one
    // place it can change. Clearing _engravedWidth kicks the fresh request.
    if (old.musicXml != widget.musicXml ||
        old.tabMode != widget.tabMode ||
        !listEquals(old.tabFingerLabels, widget.tabFingerLabels)) {
      _reservesAnnotationRoom = scoreReservesAnnotationRoom(widget.musicXml);
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
  /// geometry counts: the xml (which now differs between the plain and annotated
  /// views, since only the latter carries injected annotations), the tab variant
  /// (a second staff changes the system height), and the system spacing (which
  /// changes it directly, and so changes what the auto-fit rule can afford).
  ///
  /// The annotation lanes used to have a term here. They no longer do: they add
  /// nothing to the margins, so the only way they can move the geometry is
  /// through the xml, which is already in the key. That is what makes toggling
  /// chord symbols a repaint rather than a re-engrave.
  String _calibrationKeyFor(int spacingUnits) =>
      '${widget.musicXml.hashCode}|${widget.tabMode}|$spacingUnits';

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
      if (_calibratedFor != _calibrationKeyFor(req.spacingUnits)) {
        // BARE — the staff-spacing preference and Verovio's own page margin,
        // with no annotation reserve. The probe's job now includes measuring how
        // much room this score's layout already leaves, and it cannot measure
        // that through a reserve it was given up front.
        probe = await _engraveAt(
          req.widthPx,
          staffScaleProbe,
          spacingSystem: req.spacingUnits,
        );
        if (!mounted || seq != _engraveSeq) return;
        _unitsPerMeasure = 0; // fresh bound; the probe is its first observation
        _refinements = 0;
        _measureCount = probe.measures.length;
        _calibratedFor = _calibrationKeyFor(req.spacingUnits);
        _tightenCalibration(probe);

        // What the rows are short of, if anything, at Verovio's own spacing.
        if (_reservesAnnotationRoom) {
          final room = annotationRoomOf(probe);
          final reserve = annotationReserveFor(
            interSystemRoomSpaces: room.inter,
            firstSystemRoomSpaces: room.first,
            wantSpaces: annotationWantSpaces(probe, staffScaleProbe),
          );
          _reserveSpacingUnits = reserve.spacingUnits;
          _reservePageMarginUnits = reserve.pageMarginTopUnits;
        } else {
          _reserveSpacingUnits = 0;
          _reservePageMarginUnits = 0;
        }

        // The auto-fit predicts total height from this, and
        // `systemHeightViewBox` INCLUDES the inter-system gap — so a bare probe
        // under-reports by exactly the reserve the real engrave is about to add.
        // Add it back before `autoMeasuresPerLine` reads it, or the fit
        // overfills the viewport and the score runs off the bottom.
        _systemHeightPx =
            probe.systemHeightViewBox +
            _reserveSpacingUnits *
                spacesPerSpacingSystemUnit *
                probe.staffSpaceViewBox;
      }

      // 2. Resolve the target and solve for Verovio's scale.
      final target =
          req.target ??
          autoMeasuresPerLine(
            widthPx: req.widthPx,
            viewportHeightPx: req.viewportHeightPx,
            shortestSidePx: req.shortestSidePx,
            unitsPerMeasure: _unitsPerMeasure,
            systemHeightPx: _systemHeightPx,
            measureCount: _measureCount,
          );
      final scale = scaleFor(
        widthPx: req.widthPx,
        unitsPerMeasure: _unitsPerMeasure,
        n: target,
      );
      // The zoom decision, in one line. Worth keeping: everything here is an
      // input to a layout the user perceives as one thing ("how big are the
      // notes"), and the failure that produced this logging — target 3 engraving
      // as 4 — is invisible without seeing `target` next to the engraver's own
      // achieved `mpl`. Read the two lines together.
      if (VerovioEngraver.debugLogging) {
        debugPrint(
          '[auto] w=${req.widthPx.round()} '
          'vh=${req.viewportHeightPx.round()} '
          'budget=${(req.viewportHeightPx * staffAutoFillFraction).round()} '
          'upm=${_unitsPerMeasure.toStringAsFixed(1)} '
          'sysH=${_systemHeightPx.toStringAsFixed(1)} bars=$_measureCount '
          'reserve=${_reserveSpacingUnits}u/${_reservePageMarginUnits}m '
          'floor=${minStaffScaleFor(req.shortestSidePx).toStringAsFixed(1)} '
          'ceiling=${maxMeasuresPerLineFor(widthPx: req.widthPx, unitsPerMeasure: _unitsPerMeasure, shortestSidePx: req.shortestSidePx)} '
          '${req.target == null ? 'auto' : 'set'}=$target '
          'scale=${scale.toStringAsFixed(1)} refine=$_refinements',
        );
      }

      // 3. Engrave for real — unless the probe already produced exactly this
      //    layout. Both remaining options must match, not just the scale: reusing
      //    a probe whose page was shorter would silently clip a long score's tail
      //    (only page 1 is ever rendered). Bar numbering used to be a third term
      //    here; it no longer varies, both engraves passing mnumInterval 0.
      //    The probe is engraved BARE, so it is only reusable when the score
      //    turned out to need no reserve at all — otherwise it is a different
      //    layout from the one we are about to ask for.
      final reusable =
          probe != null &&
          (scale - staffScaleProbe).abs() < 0.05 &&
          _pageHeightFor(target) == _probePageHeightUnits &&
          _reserveSpacingUnits == 0 &&
          _reservePageMarginUnits == 0;
      final score = reusable
          ? probe
          : await _engraveAt(
              req.widthPx,
              scale,
              measuresPerLine: target,
              spacingSystem: (req.spacingUnits + _reserveSpacingUnits).clamp(
                0,
                verovioSpacingSystemMax,
              ),
              pageMarginTopReserve: _reservePageMarginUnits,
            );
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
        _engravedSpacingUnits = req.spacingUnits;
        // The real layout has landed, so a pinch preview standing in for it has
        // nothing left to say. Cleared here rather than at the release so the
        // page doesn't shrink back for the length of the engrave.
        _pinchScale = 1;
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

      // 4. Learn from what just happened. This engrave is itself an observation
      //    of how tightly Verovio packs these bars, and it is a tighter one than
      //    the probe whenever it fit more measures per line than it was asked
      //    for. If the bound moves enough to change the solve, engrave once more
      //    at the corrected scale — that is the difference between "3 bars a
      //    line, notes sized for 3" and "4 bars a line, notes sized for 3".
      if (_tightenCalibration(score) &&
          _refinements < _maxRefinements &&
          _pending == null) {
        final corrected = scaleFor(
          widthPx: req.widthPx,
          unitsPerMeasure: _unitsPerMeasure,
          n: target,
        );
        if ((corrected - scale).abs() / scale > _refineScaleThreshold) {
          _refinements++;
          _request(req);
        }
      }
    } catch (e) {
      if (mounted && seq == _engraveSeq) {
        setState(() {
          _error = '$e';
          _pinchScale = 1; // nothing is coming; don't strand the preview
        });
      }
    }
  }

  /// Backstop on corrective engraves per calibration (see [_refinements]).
  static const _maxRefinements = 2;

  /// How much the solved scale must move to be worth a corrective engrave. 3% is
  /// below the threshold of noticing a size change but far under the ~25% error
  /// a loose probe can produce, so a real miscalibration always clears it and
  /// rounding never does.
  static const _refineScaleThreshold = 0.03;

  /// Folds [score] into the running measure-width bound: it proves that
  /// `measuresPerLine` bars fit in `pageWidthUnits`, so the natural width is at
  /// most their quotient. Returns whether the bound actually fell.
  ///
  /// Only ever tightens (never loosens), so a later engrave that happens to pack
  /// loosely — the corrective one usually does, having been given the room it
  /// asked for — cannot undo the correction and start it oscillating.
  bool _tightenCalibration(EngravedScore score) {
    final before = _unitsPerMeasure;
    _unitsPerMeasure = tighterUnitsPerMeasure(
      before,
      unitsPerMeasureFrom(
        pageWidthUnits: score.pageWidthUnits,
        measuresPerLine: measuresPerLineOf(score.measureLine),
      ),
    );
    return _unitsPerMeasure < before; // false on the first observation
  }

  // The calibration probe's option set is deliberately the pre-zoom one, so an
  // un-zoomed piece reuses the engraver cache entry it always had.
  static const _probePageHeightUnits = 60000;

  /// Page height for a [measuresPerLine] layout. Only page 1 is ever rendered,
  /// so the page must hold every system — and zooming in multiplies them.
  int _pageHeightFor(int measuresPerLine) => pageHeightUnitsFor(
    measureCount: _measureCount,
    measuresPerLine: measuresPerLine,
    systemHeightPx: _systemHeightPx,
  );

  Future<EngravedScore> _engraveAt(
    double widthPx,
    double scale, {
    int? measuresPerLine,
    required int spacingSystem,
    int pageMarginTopReserve = 0,
  }) {
    return VerovioEngraver.instance.engrave(
      widget.musicXml,
      widthPx: widthPx,
      scale: scale,
      spacingSystem: spacingSystem,
      // System 0's rows come out of the page's top margin, there being no
      // system above it to borrow from. Passed in rather than derived here: the
      // probe engraves bare so it can MEASURE what the margin already gives,
      // and only the real engrave carries the reserve that measurement asked
      // for. See [annotationReserveFor].
      pageMarginTop: (verovioPageMarginTopDefault + pageMarginTopReserve).clamp(
        0,
        verovioPageMarginTopMax,
      ),
      pageHeightUnits: measuresPerLine == null
          ? _probePageHeightUnits
          : _pageHeightFor(measuresPerLine),
      // mnumInterval is left at its 0 default — no engraved bar numbers. They
      // were drawn into the same whitespace the annotation lanes use, so they
      // landed on top of the fingering row.
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
    if (score == null || _layoutWidth <= 0 || score.viewBox.width <= 0)
      return 1;
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
    final target = (m.rect.top * _scale - 12).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  // ── Count-in ───────────────────────────────────────────────────────────

  /// Where the count-off goes, in screen pixels: the top annotation lane of the
  /// system holding the measure playback is about to start on, left-aligned to
  /// that system's time signature.
  ///
  /// The system comes from the START MEASURE rather than always being the first
  /// one, so counting into a practice range at bar 30 puts the numbers on the
  /// staff you are looking at instead of eight systems up. Only the first system
  /// carries an engraved meter, so later ones fall back to the start measure's
  /// own left edge — the point the music resumes from, which is the nearest thing
  /// that line has to a signature.
  ///
  /// The rect stops at the first chord bar on that line: the chord name is what
  /// the player needs to see while the count runs, so the count-off lives in the
  /// blank space to its left (the clef/key/meter and, usually, the pickup bar)
  /// and is scaled down to fit rather than allowed to cross into it.
  Rect? _countInRect(
    EngravedScore score,
    CountInTick tick,
    double scale,
    double width,
  ) {
    final found = widget.measureNumbers.indexOf(tick.startMeasure);
    final index = found < 0 ? 0 : found;
    final line = score.lineOfMeasure(index);
    if (line < 0 || line >= score.lineContent.length) return null;
    final anchor = score.meterSigOnLine(line) ?? score.measureAt(index)?.rect;
    if (anchor == null) return null;
    // The top of this system's ink, which after injection already includes the
    // annotation rows — so the count sits above everything rather than needing a
    // lane of its own. Legibility wins over fitting: a tight system grows the
    // count upward into the margin rather than shrinking the type.
    final bottom = score.lineContent[line].top * scale;
    final height = math.max(
      18.0,
      annotationFontSizeFor(score.staffSpaceViewBox * scale) /
          chordLabelSizeFraction,
    );
    final top = math.max(0.0, bottom - height);
    final left = anchor.left * scale;
    // A chord on the very first bar leaves no blank space at all (its bar starts
    // at the barline, left of the clef). Rather than scale the count into
    // nothing, give it a legible minimum and let it overlap in that one case —
    // there is no layout answer there, only a choice of which thing to spoil.
    final chordLeft = _firstChordLeftOnLine(score, line, scale);
    final right = chordLeft == null
        ? width
        : math.min(
            width,
            math.max(chordLeft - _countInChordGap, left + _countInMinWidth),
          );
    return Rect.fromLTRB(left, top, right, top + height);
  }

  /// Left edge (screen px) of the leftmost chord bar on system line [l], or null
  /// when that line carries no chord. Same geometry the chord lane paints with,
  /// so the two can't disagree about where the bar begins.
  double? _firstChordLeftOnLine(EngravedScore score, int l, double scale) {
    double? best;
    for (final run in widget.chordRuns) {
      for (final e in runRowExtents(
        score,
        startMeasureIndex: run.startMeasureIndex,
        startNote: run.startNote,
        endMeasureIndex: run.endMeasureIndex,
        endNote: run.endNote,
      )) {
        if (e.line != l) continue;
        final left = e.left * scale;
        if (best == null || left < best) best = left;
      }
    }
    return best;
  }

  /// Clear space left between the count-off and the chord bar, and the width
  /// below which squeezing the count is worse than overlapping.
  static const _countInChordGap = 4.0;
  static const _countInMinWidth = 84.0;

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
    //
    // The same gate covers rotation, which is the other way the setting can be
    // in flight — and there it is load-bearing, not just an optimisation. The
    // zoom is stored per orientation, but `staffOrientationProvider` is pushed
    // from the screen's layout a frame later, so for that one frame the new
    // width is paired with the OLD orientation's target. Left alone, every
    // rotation engraves the other orientation's zoom (measured: a portrait
    // setting of 1 engraved at `scale` 150 across the landscape width) and then
    // throws it away. Holding off while the provider disagrees with MediaQuery
    // costs a frame and saves that engrave.
    final screen = MediaQuery.sizeOf(context);
    final orientation = screen.width >= screen.height
        ? StaffOrientation.landscape
        : StaffOrientation.portrait;
    final waitingForZoom =
        widget.zoomable &&
        (!zoom.restored || ref.watch(staffOrientationProvider) != orientation);
    // Vertical gap between systems: the preference ALONE. The annotation
    // reserve used to be added here, from a constant; it is now measured off the
    // calibration probe in [_engrave] and added to the real engrave only. Which
    // also makes this the honest key for the staleness check and the calibration
    // key — they now key on an input the user controls rather than on a derived
    // value that moves underneath them.
    final spacingUnits = verovioSpacingSystemFor(
      ref.watch(staffSpacingProvider),
    );
    // Device class for the auto-fit's minimum physical note size. The SCREEN's
    // shortest side, not this widget's box: it has to mean "phone or tablet",
    // which the render width can't say (a phone in landscape is wider than an
    // iPad in portrait) and a preview's little box certainly can't.
    final shortestSide = screen.shortestSide;
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
            spacingUnits != _engravedSpacingUnits;
        if (width > 0 && !waitingForZoom && stale()) {
          // Scheduled post-frame so we don't setState during layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !waitingForZoom && stale()) {
              _request((
                widthPx: width,
                viewportHeightPx: viewportHeight,
                shortestSidePx: shortestSide,
                target: target,
                spacingUnits: spacingUnits,
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
        _renderHeight = renderH;
        return SingleChildScrollView(
          controller: _scrollController,
          // The pinch preview. Transform.scale changes what is drawn without
          // changing what is laid out, so the page grows past its box and the
          // scroll view's own clip trims it — which is what "zoomed into the
          // page" looks like. No ClipRect needed. It sits above the
          // GestureDetector, so Flutter un-transforms tap coordinates for free,
          // and every overlay below (cursor, lanes, count-in) tracks the preview
          // without knowing about it.
          child: _pinchable(
            child: Transform.scale(
              scale: _pinchScale,
              alignment: _pinchAnchor,
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
                        child: ScalableImageWidget(
                          si: image,
                          fit: BoxFit.fitWidth,
                        ),
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
                      // The two lanes last, so a lane whose y-estimate drifts stays
                      // visible rather than hiding under a stem or a bar number.
                      // Their bands never overlap, so the order between them is
                      // arbitrary — fingering first only because it is the lower one.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _FingeringLanePainter(
                              score: score,
                              scale: scale,
                              annotations: widget.fingeringAnnotations,
                              stringRuns: widget.stringRuns,
                              style: widget.stringColourStyle,
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _ChordLanePainter(
                              score: score,
                              scale: scale,
                              runs: widget.chordRuns,
                            ),
                          ),
                        ),
                      ),
                      // Above everything, and only for the couple of seconds it is
                      // counting: it may well land on top of the first chord bar,
                      // and while it's there it is the thing being read.
                      if (widget.countInNotifier != null)
                        ValueListenableBuilder<CountInTick?>(
                          valueListenable: widget.countInNotifier!,
                          builder: (context, tick, _) {
                            final box = tick == null
                                ? null
                                : _countInRect(score, tick, scale, width);
                            if (box == null) return const SizedBox.shrink();
                            return Positioned(
                              left: box.left,
                              top: box.top,
                              child: IgnorePointer(
                                child: SizedBox(
                                  width: box.width,
                                  height: box.height,
                                  // Scale-down rather than clip: a count that loses
                                  // its last numbers stops answering "how long have
                                  // I got?", which is most of its job.
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: CountInLabel(
                                      tick: tick!,
                                      height: box.height,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Wraps the page in the two-finger zoom gesture — or doesn't, for the
  /// previews (measure editor, palette), which opt out of the whole-piece zoom
  /// via `zoomable: false` and would otherwise let a pinch resize their one bar.
  ///
  /// A RawGestureDetector rather than a GestureDetector because the recognizer
  /// has to be the gated one: a stock ScaleGestureRecognizer treats a lone
  /// pointer as a pan and would take one-finger drags away from the enclosing
  /// SingleChildScrollView, costing the score its scrolling.
  Widget _pinchable({required Widget child}) {
    if (!widget.zoomable) return child;
    return RawGestureDetector(
      gestures: {
        _PinchOnlyScaleRecognizer:
            GestureRecognizerFactoryWithHandlers<_PinchOnlyScaleRecognizer>(
              () => _PinchOnlyScaleRecognizer(debugOwner: this),
              (r) => r
                ..onStart = _onScaleStart
                ..onUpdate = _onScaleUpdate
                ..onEnd = _onScaleEnd,
            ),
      },
      child: child,
    );
  }

  static int _bucket(double w) => (w / 48).round();
}

/// A [ScaleGestureRecognizer] that cannot win on a single pointer.
///
/// The staff sits inside a [SingleChildScrollView], so its vertical drag
/// recognizer is in the arena on every touch. A stock scale recognizer treats
/// one pointer as a pan, declares victory once it clears its slop, and the score
/// stops scrolling. Withholding sub-two-pointer moves from the state machine is
/// what keeps it from ever getting that far — it stays unresolved and is simply
/// rejected when the scroll view claims the gesture.
class _PinchOnlyScaleRecognizer extends ScaleGestureRecognizer {
  _PinchOnlyScaleRecognizer({super.debugOwner});

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && pointerCount < 2) return;
    super.handleEvent(event);
  }
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

    final byLine =
        <int, ({double left, double right, double top, double bottom})>{};
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
        _scaled(Rect.fromLTRB(s.left, s.top, s.right, s.bottom)),
    ];
  }

  Rect _scaled(Rect r) => Rect.fromLTRB(
    r.left * scale,
    r.top * scale,
    r.right * scale,
    r.bottom * scale,
  );

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

/// Drawn in the channel BETWEEN the notes and the chord lane: one coloured chip
/// per fingering label, every chip on a system at the same height.
///
/// The room the tightest system offers for the annotation stack, in screen px:
/// from the previous system's ink down to that system's own annotation register.
///
/// Score-wide MINIMUM, deliberately, because [annotationStackFor] has to give one
/// answer for every system — see there for why uniformity matters more here than
/// letting each system use what it happens to have.
/// The room the annotation stack has, in staff spaces, split by what Verovio
/// charges for it: system 0's comes out of `pageMarginTop`, everything else out
/// of `spacingSystem`. `infinity` means "no system of that kind draws anything",
/// which asks for no reserve rather than an infinite one.
///
/// Staff spaces, not px, because the caller compares this against a probe engrave
/// at a different scale — see [annotationReserveFor].
({double first, double inter}) annotationRoomOf(EngravedScore score) {
  var first = double.infinity;
  var inter = double.infinity;
  final space = score.staffSpaceViewBox;
  if (space <= 0) return (first: first, inter: inter);
  for (var l = 0; l < score.lineCount; l++) {
    // The same register [_annotationBudget] sizes the stack against, so the
    // reserve is priced for the thing it actually has to make fit.
    final register = score.fingRegister(l) ?? score.harmRegister(l);
    if (register == null) continue;
    final prev = l <= 0 ? 0.0 : score.lineContent[l - 1].bottom;
    final room = (register - prev) / space;
    if (l == 0) {
      if (room < first) first = room;
    } else if (room < inter) {
      inter = room;
    }
  }
  return (first: first, inter: inter);
}

/// What the stack wants when nothing is in the way, in staff spaces — the target
/// [annotationReserveFor] measures the shortfall against.
///
/// Scale-invariant, so it can be read off the probe: every term in
/// [annotationStackFor] is a fraction of `staffSpacePx`, so dividing back out by
/// it cancels the scale.
double annotationWantSpaces(EngravedScore score, double scale) {
  final space = score.staffSpaceViewBox * scale;
  if (space <= 0) return 0;
  final full = annotationStackFor(
    budgetPx: double.infinity,
    staffSpacePx: space,
    labelShare: chordLabelSizeFraction,
    typeShare: underlineTextFraction,
    withChordBar: score.harmAnchors.isNotEmpty,
    withFingeringRow: score.fingAnchors.isNotEmpty,
  );
  return (full.barHeight + full.channelHeight + full.gap) / space;
}

double _annotationBudget(EngravedScore score, double scale) {
  var budget = double.infinity;
  for (var l = 0; l < score.lineCount; l++) {
    final register = score.fingRegister(l) ?? score.harmRegister(l);
    if (register == null) continue;
    final prev = l <= 0 ? 0.0 : score.lineContent[l - 1].bottom;
    final room = (register - prev) * scale;
    if (room < budget) budget = room;
  }
  return budget.isFinite ? budget : 0;
}

/// The annotation stack for [score] — one chord-bar height and one fingering
/// channel height, used on every system. See [annotationStackFor].
({double barHeight, double channelHeight, double gap}) annotationStackOf(
  EngravedScore score,
  double scale,
) => annotationStackFor(
  budgetPx: _annotationBudget(score, scale),
  staffSpacePx: score.staffSpaceViewBox * scale,
  labelShare: chordLabelSizeFraction,
  typeShare: underlineTextFraction,
  // Only the rows this score will actually draw get to claim room. Verovio
  // engraved no `<harm>` ⇒ `harmRegister` is null on every system ⇒ no bar is
  // ever painted, and the same for the channel in the tab view.
  withChordBar: score.harmAnchors.isNotEmpty,
  withFingeringRow: score.fingAnchors.isNotEmpty,
);

/// The fingering channel on system [line], in screen px — or null when that
/// system carries no engraved fingering.
///
/// Top-level because BOTH lane painters need it: the chord bar sits directly on
/// top of this, so it has to know where the row ends. That relationship used to
/// be structural — the old lane slots tiled, so slot 1's floor WAS slot 0's
/// ceiling — and registers don't tile, so it has to be stated.
///
/// The bottom edge is [EngravedScore.fingRegister], the topmost baseline Verovio
/// chose on that system, so the row clears every notehead on it. The height is
/// the score-wide one, so the row is the same thickness on every system.
Rect? fingeringChannelOn(
  EngravedScore score,
  int line,
  double scale,
  double width,
) {
  final register = score.fingRegister(line);
  if (register == null) return null;
  final h = annotationStackOf(score, scale).channelHeight;
  if (h <= 0) return null;
  final bottom = register * scale;
  return Rect.fromLTRB(0, bottom - h, width, bottom);
}

/// The flat level is the entire point. These labels used to be engraved by
/// Verovio as `<fing>` elements, which places each one above its own notehead —
/// so the fingering rose and fell with the melody and had to be read as a
/// contour rather than scanned as a row. Drawing on
/// [EngravedScore.fingRegister] — the topmost baseline Verovio chose on that
/// system — keeps the row flat while still clearing every notehead on it.
///
/// The fingerings ARE engraved again, but their ink is cut back out
/// ([VerovioEngraver.stripAnnotationGlyphs]); they exist only so Verovio reserves
/// the row and reports where it put it. That inflates each measure's bbox, which
/// is what used to squeeze the old whitespace-derived lane to nothing — here it is
/// the mechanism rather than the bug.
///
/// The chip's FILL is the string (see [ViolinStringPalette]) and its text is the
/// finger, which is why the G/D/A/E letter can be dropped from the label — but
/// that choice is made upstream in [fingeringAnnotations]; this painter draws
/// whatever label it is handed, verbatim.
class _FingeringLanePainter extends CustomPainter {
  _FingeringLanePainter({
    required this.score,
    required this.scale,
    required this.annotations,
    required this.stringRuns,
    required this.style,
  });

  final EngravedScore score;
  final double scale;
  final List<FingeringAnnotation> annotations;

  /// Unbroken spans on one string, for [StringColourStyle.underline]. Empty for
  /// the other styles, which say nothing about notes that carry no label.
  final List<StringRunRegion> stringRuns;

  final StringColourStyle style;

  /// Chip height as a fraction of the CHANNEL, capping how much of the lane a
  /// chip may claim; the remainder is the air that stops the row reading as one
  /// solid ribbon (and, in the annotation view, keeps it clear of the chord bar
  /// directly above).
  ///
  /// A ceiling, not the size: the chip is sized to fit its TYPE
  /// (`annotationFontSizeFor`), and only clamped by this. It was the other way
  /// round — chip from the lane, type from the chip — which is what left the
  /// digits at two thirds of a notehead. See the annotation-type notes in
  /// `staff_zoom.dart`.
  static const _chipChannelFraction = 0.88;

  /// The type's share of the chip's height. What's left is the chip's vertical
  /// padding, so this is really "how tight is the capsule around the digits" —
  /// 0.78 puts a comfortable but not loose ring around a `2L`.
  static const _chipTypeFraction = 0.78;

  /// Horizontal padding inside a chip, and the minimum clear space between two
  /// chips, both as fractions of the chip height.
  static const _chipPadFraction = 0.26;
  static const _chipGapFraction = 0.14;

  // The underline style's vertical budget — rule, gap, stagger step and what's
  // left for the digits — lives with the palette (`violin_string_palette.dart`),
  // next to the string order it staggers by and the channel height it sets.

  @override
  void paint(Canvas canvas, Size size) {
    if (annotations.isEmpty) return;

    // Group by system line and sort by x: the channel is drawn per line, and the
    // overlap guard has to walk each line left to right.
    final byLine = <int, List<({double cx, FingeringAnnotation a})>>{};
    for (final a in annotations) {
      final line = score.lineOfMeasure(a.measureIndex);
      if (line < 0) continue;
      final note = score.noteAt(a.measureIndex, a.noteIndex);
      if (note == null) continue;
      (byLine[line] ??= []).add((cx: note.rect.center.dx, a: a));
    }

    if (style == StringColourStyle.underline) {
      _paintStringRuns(canvas, size.width);
    }

    for (final entry in byLine.entries) {
      final channel = _channelFor(entry.key, size.width);
      if (channel == null)
        continue; // nothing engraved here — skip, don't clash
      final items = entry.value..sort((p, q) => p.cx.compareTo(q.cx));
      if (style == StringColourStyle.underline) {
        _paintNumbers(canvas, items, channel);
      } else {
        // The grey strip is the chips' background, so it takes the chips' own
        // band — sized from the type (see [_paintChips]), not the whole channel.
        // A strip shorter than the chips on it reads as a misalignment.
        _paintChannel(canvas, _chipBand(channel));
        _paintChips(canvas, items, channel);
      }
    }
  }

  Rect? _channelFor(int line, double width) =>
      fingeringChannelOn(score, line, scale, width);

  /// The chips' own band (see [_chipBand]), spanning the full render width.
  ///
  /// Full width rather than the system's ink extent: the channel reads as a
  /// staff-wide register you scan along, and a strip that stopped at the last
  /// measure of a short final system would look like a mistake rather than like a
  /// lane. Squared off for the same reason — it's a rule, not a badge.
  ///
  /// Not drawn in [StringColourStyle.underline]: the grey exists to keep a
  /// saturated chip (the E-string yellow especially) from dissolving into the
  /// page, and near-black digits have no such problem. The band is still
  /// RESERVED there — the engrave sees to that — it just isn't painted, so the
  /// numbers sit on the page and the coloured rule is the only horizontal
  /// element in the lane.
  void _paintChannel(Canvas canvas, Rect channel) {
    canvas.drawRect(channel, Paint()..color = fingeringChannelColor);
  }

  /// The string track: one coloured rule per run, low in the channel, joined for
  /// as long as the playing stays on a string — and lifted clear of the floor by
  /// the run's string, so the four strings occupy four levels.
  ///
  /// The level is the second half of the cue. Colour says which string; the step at
  /// a join says which WAY, up or down, which is the thing a player has to know
  /// before the note rather than after it. The two are redundant on purpose: the
  /// levels survive being unable to tell dark green from blue.
  ///
  /// Drawn from [stringRuns] rather than from [annotations], so it spans notes
  /// whose number the density filter dropped — the rule answers "which string am
  /// I on?" continuously, which is most of its value at the lower densities.
  void _paintStringRuns(Canvas canvas, double width) {
    for (final run in stringRuns) {
      final colour = ViolinStringPalette.rule(run.string);
      for (final e in runRowExtents(
        score,
        startMeasureIndex: run.startMeasureIndex,
        startNote: run.startNote,
        endMeasureIndex: run.endMeasureIndex,
        endNote: run.endNote,
        clipStartToNote: true,
      )) {
        // The same channel the numbers use, so the rule and the digits above it
        // cannot disagree about where the register is.
        final channel = _channelFor(e.line, width);
        if (channel == null) continue;
        final channelH = channel.height;
        final h = channelH * underlineRuleFraction;
        if (h <= 0) continue;
        final bottom = channel.bottom - _lift(run.string, channelH);
        // A hairline off each end, so two runs that meet at a string change read
        // as two rules rather than one that changes colour mid-stroke.
        final rect = Rect.fromLTRB(
          e.left * scale + _runGap,
          bottom - h,
          e.right * scale - _runGap,
          bottom,
        );
        if (rect.width <= 0) continue;
        // Rounded only at the run's true ends; a wrap onto the next system is
        // square-cut so it reads as "carries on". Same convention as the chord
        // bars directly above.
        final cap = Radius.circular(h / 2);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: e.isFirst ? cap : Radius.zero,
            bottomLeft: e.isFirst ? cap : Radius.zero,
            topRight: e.isLast ? cap : Radius.zero,
            bottomRight: e.isLast ? cap : Radius.zero,
          ),
          Paint()..color = colour,
        );
      }
    }
  }

  static const _runGap = 1.0;

  /// How far above the channel's floor [string]'s rule and number sit, in screen
  /// pixels, for a channel [channelH] tall. G sits on the floor; each string above
  /// it rises one [underlineStringStepFraction].
  double _lift(String? string, double channelH) =>
      ViolinStringPalette.stepOf(string) *
      channelH *
      underlineStringStepFraction;

  /// Near-black numbers above the string track. No chip, no fill — the point of
  /// this style is that nothing competes with the digits.
  ///
  /// Each number rides its own string's level, so it stays glued to the rule under
  /// it. That means the row of numbers is no longer perfectly flat — deliberately:
  /// a number that stayed put while its rule stepped away would be reading against
  /// the cue instead of with it. The step is a fraction of the type size, so the
  /// row still scans as a row (see [underlineStringStepFraction]).
  void _paintNumbers(
    Canvas canvas,
    List<({double cx, FingeringAnnotation a})> items,
    Rect channel,
  ) {
    // Same want as the chips, but this style's ceiling is its own stack budget
    // (rule + gap + four stagger steps + digits), not the whole channel — so the
    // numbers grow toward "slightly larger than a notehead" only as far as the
    // stagger leaves room, and never overrun the rule they sit on.
    final textH = annotationFontSizeIn(
      staffSpacePx: score.staffSpaceViewBox * scale,
      laneHeightPx: channel.height,
      laneTypeShare: underlineTextFraction,
    );
    if (textH <= 0) return;
    // The digits sit in the space above the rule, bottom-aligned to it so the
    // number and its colour read as one mark.
    final floor =
        channel.bottom -
        channel.height * (underlineRuleFraction + underlineRuleGapFraction);
    final gap = textH * _chipGapFraction;

    var prevRight = double.negativeInfinity;
    for (final item in items) {
      final baseline = floor - _lift(item.a.string, channel.height);
      final tp = TextPainter(
        text: TextSpan(
          text: item.a.label,
          style: TextStyle(
            fontSize: textH,
            height: 1.0,
            fontWeight: FontWeight.w700,
            color: fingeringInk,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final left = item.cx * scale - tp.width / 2;
      // Same left-to-right first-come guard as the chips; without a chip's
      // padding the numbers would otherwise touch.
      if (left < prevRight + gap) continue;
      prevRight = left + tp.width;
      tp.paint(canvas, Offset(left, baseline - tp.height));
    }
  }

  /// The type size for chips in [channel] (the WHOLE fingering channel, not
  /// what the staff asks for, capped by what the channel can host.
  ///
  /// The cap cuts both ways — it keeps a tall channel (a wide-ranging melody, or
  /// a generous staff spacing) from inflating the chips past "slightly larger
  /// than a notehead", and a short one from letting them spill onto the staff.
  double _fontSizeIn(Rect channel) => annotationFontSizeIn(
    staffSpacePx: score.staffSpaceViewBox * scale,
    laneHeightPx: channel.height,
    laneTypeShare: _chipChannelFraction * _chipTypeFraction,
  );

  /// The band the chips occupy: sized from the type, and bottom-anchored on the
  /// chip zone's floor — the edge that is fixed relative to the notes — so taller
  /// chips grow UP into the lane's own slack rather than down onto the staff.
  Rect _chipBand(Rect channel) {
    final chipH = math.min(
      _fontSizeIn(channel) / _chipTypeFraction,
      channel.height * _chipChannelFraction,
    );
    // The channel floor IS the register Verovio engraved, so the chips sit on
    // the line it chose and grow upward from it.
    final bottom = channel.bottom;
    return Rect.fromLTRB(channel.left, bottom - chipH, channel.right, bottom);
  }

  /// [channel] is the WHOLE fingering channel: the chips are
  /// sized from the staff and may use any of it, up to [_chipChannelFraction].
  void _paintChips(
    Canvas canvas,
    List<({double cx, FingeringAnnotation a})> items,
    Rect channel,
  ) {
    // Type first, chip around it — the inverse of the old chain, which sized the
    // chip from the lane and then the type from the chip.
    final fontSize = _fontSizeIn(channel);
    final band = _chipBand(channel);
    final chipH = band.height;
    if (fontSize <= 0 || chipH <= 0) return;
    final pad = chipH * _chipPadFraction;
    final gap = chipH * _chipGapFraction;
    final cy = band.center.dy;

    var prevRight = double.negativeInfinity;
    for (final item in items) {
      // Neutral when the labels carry the string as a letter instead — the chip
      // still needs a fill to read as a chip, it just mustn't claim to mean
      // anything.
      final fill = style == StringColourStyle.chips
          ? ViolinStringPalette.of(item.a.string)
          : fingeringChipNeutral;
      final tp = TextPainter(
        text: TextSpan(
          text: item.a.label,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.0,
            fontWeight: FontWeight.w700,
            color: ViolinStringPalette.inkOn(fill),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

      // Square-ish minimum so a lone '2' isn't a thin sliver next to a '2L'.
      final w = math.max(tp.width + pad * 2, chipH);
      final left = item.cx * scale - w / 2;

      // Left to right, first come first served. At a tight zoom (or one measure
      // per line) the chips would otherwise smear into an unreadable band; the
      // density slider is the user's control for having fewer of them.
      if (left < prevRight + gap) continue;
      prevRight = left + w;

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, cy - chipH / 2, w, chipH),
        Radius.circular(chipH * chordSwatchRadiusFraction),
      );
      canvas.drawRRect(rrect, Paint()..color = fill);
      // A hairline edge in a darker shade of the fill, for the same reason the
      // chord swatch has one: the E-string yellow on the grey channel needs its
      // shape defined, and doing it in the fill's own hue costs no colour budget.
      final edge = (chipH * 0.07).clamp(0.5, 1.5);
      canvas.drawRRect(
        rrect.deflate(edge / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = edge
          ..color = ChordPalette.dim(fill).withValues(alpha: 0.85),
      );
      tp.paint(canvas, Offset(left + (w - tp.width) / 2, cy - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_FingeringLanePainter old) =>
      old.score != score ||
      old.scale != scale ||
      old.annotations != annotations ||
      old.stringRuns != stringRuns ||
      old.style != style;
}

/// Drawn in the lane ABOVE each system: one labelled colored bar per chord run,
/// spanning exactly the notes the chord governs. The bar answers "until when?",
/// which a chord letter on its own can't, and its color keys the run to its
/// diagram in the "New chords" footer.
///
/// Horizontal geometry mirrors [_UnderlayPainter._regionRowRects] — measures
/// unioned within a system line, note-level start/end edges, one segment per line
/// so a run that wraps splits cleanly. The vertical extent comes from
/// [EngravedScore.harmRegister] — the baseline Verovio engraved its own chord
/// symbols at — so the bar lands exactly in the room reserved for it.
class _ChordLanePainter extends CustomPainter {
  _ChordLanePainter({
    required this.score,
    required this.scale,
    required this.runs,
  });

  final EngravedScore score;
  final double scale;
  final List<ChordRunRegion> runs;

  /// Hairline pulled off each end so two adjacent runs read as separate blocks
  /// rather than one continuous ribbon (their measure edges touch exactly).
  static const _gap = 1.0;


  @override
  void paint(Canvas canvas, Size size) {
    if (runs.isEmpty) return;
    for (final run in runs) {
      for (final seg in _runRowRects(run, size.width)) {
        _paintSegment(canvas, seg, run);
      }
    }
  }

  void _paintSegment(Canvas canvas, _LaneSegment seg, ChordRunRegion run) {
    final r = seg.rect;
    if (r.width <= 0 || r.height <= 0) return;
    final cap = Radius.circular(r.height * chordSwatchRadiusFraction);
    // Square-cut the edge where a run continues onto the next system, so the
    // wrap reads as "carries on" rather than as two separate chords.
    paintChordSwatch(
      canvas,
      RRect.fromRectAndCorners(
        r,
        topLeft: seg.isFirst ? cap : Radius.zero,
        bottomLeft: seg.isFirst ? cap : Radius.zero,
        topRight: seg.isLast ? cap : Radius.zero,
        bottomRight: seg.isLast ? cap : Radius.zero,
      ),
      degree: run.degree,
      minor: run.minorQuality,
    );
    final fill = ChordPalette.of(run.degree, minor: run.minorQuality);

    // Label. Repeated on every wrapped segment, so a system read on its own
    // still names its chord; dropped when the segment is too narrow for it
    // (a short mid-measure run), where the color alone carries the identity.
    final inset = r.height * chordLabelInsetFraction;
    final tp = TextPainter(
      text: TextSpan(text: run.label, style: chordLabelStyle(r.height, fill)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    if (tp.width + inset * 2 > r.width) return;
    tp.paint(canvas, Offset(r.left + inset, r.center.dy - tp.height / 2));
  }

  /// The vertical extent of the bar on system [line]: it sits ON the register
  /// Verovio engraved its chord symbols at, and is as tall as the label needs.
  ///
  /// [EngravedScore.harmRegister] is a true register — Verovio gives every chord
  /// symbol on a system the same baseline — so unlike the fingering channel there
  /// is nothing to reconcile here. The bar's height follows from the label:
  /// [chordLabelStyle] takes [chordLabelSizeFraction] of it for type, so the bar
  /// is `annotationFontSizeFor / chordLabelSizeFraction` tall and the chord name
  /// comes out at the same size as a fingering digit.
  ///
  /// A foot clearance is kept, still shortening from the BOTTOM only, so the
  /// fingering row below has somewhere to come up to.
  ({double top, double bottom})? _barFor(int line, double width) {
    final stack = annotationStackOf(score, scale);
    if (stack.barHeight <= 0) return null;
    // The bar sits directly on the fingering row where there is one, so the two
    // read as a stack rather than as two independently placed things; otherwise
    // it hangs off its own register.
    final channel = fingeringChannelOn(score, line, scale, width);
    final double bottom;
    if (channel != null) {
      bottom = channel.top - stack.gap;
    } else {
      // chordRegister, not harmRegister: a chord run carrying across a system
      // break leaves the continuation system with no engraved symbol, and the bar
      // has to be drawn anyway. See EngravedScore.chordRegister.
      final register = score.chordRegister(line);
      if (register == null) return null;
      bottom = register * scale - stack.gap;
    }
    return (top: bottom - stack.barHeight, bottom: bottom);
  }

  /// One segment per system line the run touches, in line order.
  List<_LaneSegment> _runRowRects(ChordRunRegion r, double width) {
    final out = <_LaneSegment>[];
    for (final e in runRowExtents(
      score,
      startMeasureIndex: r.startMeasureIndex,
      startNote: r.startNote,
      endMeasureIndex: r.endMeasureIndex,
      endNote: r.endNote,
    )) {
      final bar = _barFor(e.line, width);
      if (bar == null) continue; // nothing engraved here — skip, don't clash
      out.add(
        _LaneSegment(
          rect: Rect.fromLTRB(
            e.left * scale + _gap,
            bar.top,
            e.right * scale - _gap,
            bar.bottom,
          ),
          isFirst: e.isFirst,
          isLast: e.isLast,
        ),
      );
    }
    return out;
  }

  @override
  bool shouldRepaint(_ChordLanePainter old) =>
      old.score != score || old.scale != scale || old.runs != runs;
}

/// The horizontal extent of a note-level run, split per system line.
///
/// The shared half of what the chord lane and the fingering channel's string
/// underline both need: measures unioned within a line, note-level start/end
/// edges, one entry per line so a run that wraps splits cleanly. Only the
/// VERTICAL placement differs between the two, so only that is left to the
/// callers — which is what stops the two lanes drifting apart on where a run
/// begins and ends.
///
/// Coordinates are viewBox, unscaled. [isFirst]/[isLast] mark the run's true
/// ends, so a caller can cap those and square-cut the wraps.
///
/// [endNote] is EXCLUSIVE, with -1 meaning "the whole of [endMeasureIndex]" —
/// the [ChordRunRegion] / [StringRunRegion] / `SectionTintRegion` convention.
///
/// [clipStartToNote] pulls the very start of the run in to its first NOTE rather
/// than to its measure's left edge. The two kinds of run want different answers
/// here: a chord governs its whole bar, so its bar starts at the barline, but a
/// string run describes playing, and starting at the barline drags it back under
/// the clef and key signature on the first system — reading as a rule that
/// begins before the music does.
List<({int line, double left, double right, bool isFirst, bool isLast})>
runRowExtents(
  EngravedScore score, {
  required int startMeasureIndex,
  required int startNote,
  required int endMeasureIndex,
  required int endNote,
  bool clipStartToNote = false,
}) {
  // Last measure index that gets ink: a whole-measure end (-1) or a mid-measure
  // end (endNote>0) includes endMeasureIndex; endNote==0 stops at the measure
  // before it. Same rule as the section wash.
  final lastIdx = endNote == -1
      ? endMeasureIndex
      : (endNote > 0 ? endMeasureIndex : endMeasureIndex - 1);
  if (lastIdx < startMeasureIndex) return const [];

  final byLine = <int, ({double left, double right})>{};
  for (var i = startMeasureIndex; i <= lastIdx; i++) {
    final m = score.measureAt(i);
    if (m == null) continue;
    var left = m.rect.left;
    var right = m.rect.right;
    if (i == startMeasureIndex && (startNote > 0 || clipStartToNote)) {
      final n = score.noteAt(i, startNote);
      if (n != null) left = n.rect.left;
    }
    if (endNote > 0 && i == endMeasureIndex) {
      final n = score.noteAt(i, endNote);
      if (n != null) right = n.rect.left;
    }
    if (right <= left) continue;
    final line = score.lineOfMeasure(i);
    if (line < 0) continue;
    final cur = byLine[line];
    byLine[line] = cur == null
        ? (left: left, right: right)
        : (
            left: left < cur.left ? left : cur.left,
            right: right > cur.right ? right : cur.right,
          );
  }
  if (byLine.isEmpty) return const [];

  final lines = byLine.keys.toList()..sort();
  return [
    for (final line in lines)
      (
        line: line,
        left: byLine[line]!.left,
        right: byLine[line]!.right,
        isFirst: line == lines.first,
        isLast: line == lines.last,
      ),
  ];
}

/// One chord bar on one system line. [isFirst]/[isLast] mark the run's true ends,
/// so only those get a rounded cap.
class _LaneSegment {
  final Rect rect;
  final bool isFirst;
  final bool isLast;
  const _LaneSegment({
    required this.rect,
    required this.isFirst,
    required this.isLast,
  });
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

  Rect _scaled(Rect r) => Rect.fromLTRB(
    r.left * scale,
    r.top * scale,
    r.right * scale,
    r.bottom * scale,
  );

  int _indexOf(int measureNumber) => measureNumbers.indexOf(measureNumber);

  /// Scaled rects covering measure indices [startIdx]..[endIdx], one per system
  /// line: measures unioned horizontally, the line's tiled band as the height.
  List<Rect> _measureBandRects(int startIdx, int endIdx) {
    final byLine =
        <int, ({double left, double right, double top, double bottom})>{};
    for (var i = startIdx; i <= endIdx; i++) {
      final m = score.measureAt(i);
      final band = score.bandForMeasure(i);
      if (m == null || band == null) continue;
      final line = score.lineOfMeasure(i);
      final cur = byLine[line];
      byLine[line] = cur == null
          ? (
              left: m.rect.left,
              right: m.rect.right,
              top: band.top,
              bottom: band.bottom,
            )
          : (
              left: m.rect.left < cur.left ? m.rect.left : cur.left,
              right: m.rect.right > cur.right ? m.rect.right : cur.right,
              top: cur.top,
              bottom: cur.bottom,
            );
    }
    return [
      for (final s in byLine.values)
        _scaled(Rect.fromLTRB(s.left, s.top, s.right, s.bottom)),
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
    canvas.drawCircle(
      Offset(x + s / 2, y + s - s * 0.22),
      s * 0.09,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.score != score ||
      old.scale != scale ||
      old.selection != selection ||
      old.flaggedMeasures != flaggedMeasures ||
      old.measureNumbers != measureNumbers ||
      old.primary != primary ||
      // flagColor too: a theme change that moves only the error colour would
      // otherwise leave every flag painted in the old one.
      old.flagColor != flagColor;
}

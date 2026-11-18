import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../models/chord_palette.dart';
import '../models/engraved_measure_map.dart';
import '../models/section_palette.dart';
import '../models/violin_string_palette.dart';
import '../services/fingering_annotation_builder.dart';
import '../services/midi_generator.dart';
import '../services/playback_service_base.dart' show PlaybackState;
import '../services/providers.dart';
import '../services/section_engraving.dart';
import '../services/staff_zoom.dart';
import '../services/system_break_injector.dart';
import '../services/verovio_engraver.dart';
import 'chord_swatch.dart';
import 'measure_drag_select.dart';

/// Native staff renderer: Verovio engraves (coordinates + per-element bboxes),
/// jovial_svg draws the SVG in Flutter's own pipeline, and native CustomPaint
/// overlays draw selection, section tints, flagged-measure markers, the
/// current-note highlight, and the playback cursor.
///
/// Not a platform view, so Marionette/`simctl` screenshots capture the
/// notation.
class StaffViewVerovio extends ConsumerStatefulWidget {
  final String musicXml;
  final ValueNotifier<HighlightEvent?> highlightNotifier;
  final MeasureSelection? selection;
  final ValueChanged<int>? onMeasureTapped;

  /// Hold-and-drag range selection (see [MeasureDragSelect]): the held bar
  /// and the bar under the finger, as model measure numbers.
  final void Function(int anchor, int current)? onMeasureRange;
  final ValueChanged<bool>? onMeasureDragging;

  /// The selection's end handles: move its first ([atStart]) or last bar by
  /// [delta] bars. Null shows no handles.
  final void Function(bool atStart, int delta)? onNudgeSelection;

  /// A dragged end handle: put the selection's first ([atStart]) or last bar
  /// on [measure]. The bar itself, not a step: several moves can land in one
  /// frame, before this widget sees the selection they made.
  final void Function(bool atStart, int measure)? onMoveSelectionEdge;
  final Set<int> flaggedMeasures;

  /// Engraved measure index ↔ model measure number (and, for a bar split at a
  /// section's lead-in, the note offset of each slice), both directions.
  final EngravedMeasureMap measureMap;

  /// Lay the piece out by section: every section starts a line (the xml
  /// already carries those breaks) and fills one line, or the fewest that
  /// fit at the chosen size, balanced by measured width — see
  /// `planSectionLines` and [staffSizeProvider].
  final bool sectionLayout;

  /// With [sectionLayout]: the segments are the printed page's lines (the
  /// Like original scan), and each is kept whole — exactly the page's breaks, none
  /// added. The notes are then as big as the widest line allows, and the
  /// piece's size setting doesn't apply.
  final bool printedLines;

  /// The score the caller has for this view is being rebuilt: [musicXml] is
  /// the previous one, still shown while the new one loads, but the layout
  /// settings beside it may already be the new ones. Engraving that mixture
  /// is a full engrave of a layout nobody asked for, thrown away when the
  /// new score lands. So while holding the view engraves nothing, and dims
  /// what it has with the re-engraving spinner.
  final bool holding;

  /// Parity with [StaffView]; the engraver always wraps systems to the page
  /// width, so there's no last-system justification to toggle.
  final bool stretchLastSystem;

  /// Per-section background washes, with note-level edges (engraved-index space).
  final List<SectionTintRegion> sectionTints;

  /// With [sectionLayout]: each section's label at its engraved start
  /// position, so same-label sections take the same number of lines (see
  /// `planSectionLines`).
  final Map<int, String> sectionLabels;

  /// Chord runs, drawn as labelled colored bars in a lane above each system. This
  /// renderer owns the chord label entirely — the callers keep `<harmony>` so
  /// Verovio reserves the row, and its `<harm>` ink is cut back out of the SVG
  /// ([VerovioEngraver.stripAnnotationGlyphs]), so nothing duplicates it.
  final List<ChordRunRegion> chordRuns;

  /// Fingering labels, drawn as coloured chips in a channel between the notes and
  /// the chord lane. As with the chords, this renderer owns them entirely — the
  /// callers inject `<fingering>` only so Verovio reserves the row, and its ink
  /// is cut back out (see [_FingeringLanePainter]).
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

  /// Every note's name and string (see [noteNameLabels]) — read for the name
  /// row when [showNoteNames], and for the notehead tint when [colourNoteheads].
  final List<NoteNameLabel> noteNames;

  /// Draw [noteNames] in the row above the fingering. Claims that row even on a
  /// chord-less score, so changing it re-engraves (the reserve moves).
  final bool showNoteNames;

  /// Tint each notehead with its string's colour. A re-parse of the cached
  /// engrave, never a re-layout.
  final bool colourNoteheads;

  /// The vocabulary's key-signature labels: each accidental's letter above it,
  /// and the key's name above those. Null draws nothing. Needs [showNoteNames]
  /// for the row the key name sits in.
  final KeySignatureLabel? keySignatureLabel;

  /// Minimap scroll-to-measure request (measure index + a sequence so identical
  /// requests still fire).
  final ({int index, int seq})? scrollNav;

  /// Tab view: this score has a second (tab) staff. Excludes its notes from the
  /// anchors and keeps the per-system "T-A-B" clef.
  final bool tabMode;

  /// Tab view (fingering mode): fingering labels, in document order, swapped in
  /// for Verovio's native fret numbers. Null → fret mode (native numbers stay).
  final List<String>? tabFingerLabels;

  /// Whether the piece's [staffSizeProvider] applies. False for incidental
  /// previews (the measure editor, the note palette) that show a bar or two and
  /// should always just auto-fit their box — a whole-piece size of Small would
  /// render a single-measure preview at a fraction of its box.
  final bool zoomable;

  /// Told the height the engraved page draws at, whenever it changes — for a
  /// preview that sizes its box to its content (the note palette) rather than
  /// scrolling inside a fixed one.
  final ValueChanged<double>? onContentHeight;

  const StaffViewVerovio({
    super.key,
    required this.musicXml,
    required this.highlightNotifier,
    this.selection,
    this.onMeasureTapped,
    this.onMeasureRange,
    this.onMeasureDragging,
    this.onNudgeSelection,
    this.onMoveSelectionEdge,
    this.flaggedMeasures = const {},
    this.measureMap = EngravedMeasureMap.empty,
    this.sectionLayout = false,
    this.printedLines = false,
    this.holding = false,
    this.stretchLastSystem = true,
    this.sectionTints = const [],
    this.sectionLabels = const {},
    this.chordRuns = const [],
    this.fingeringAnnotations = const [],
    this.stringColourStyle = StringColourStyle.chips,
    this.stringRuns = const [],
    this.noteNames = const [],
    this.showNoteNames = false,
    this.colourNoteheads = false,
    this.keySignatureLabel,
    this.scrollNav,
    this.tabMode = false,
    this.tabFingerLabels,
    this.zoomable = true,
    this.onContentHeight,
  });

  @override
  ConsumerState<StaffViewVerovio> createState() => _StaffViewVerovioState();
}

/// One engrave request: the box to fill, the note size (Fit is resolved against
/// [viewportHeightPx] once calibrated), and the vertical gap between systems.
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
/// One calibration's measurements (see `_StaffViewVerovioState._calibrate`).
typedef _Calibration = ({
  double unitsPerMeasure,
  double systemHeightPx,
  int measureCount,
  int refinements,
  int reserveSpacingUnits,
  int reservePageMarginUnits,
});

typedef _EngraveRequest = ({
  double widthPx,
  double viewportHeightPx,
  double shortestSidePx,
  StaffSize size,
  int spacingUnits,
  bool sections,
});

class _StaffViewVerovioState extends ConsumerState<StaffViewVerovio> {
  final _scrollController = ScrollController();

  /// The engraved page inside the scroll view: global → page coordinates
  /// for the hold-and-drag, whose positions arrive global.
  final _pageKey = GlobalKey();

  /// A hold-and-drag is in progress: the end handles step aside.
  bool _dragging = false;

  /// The end handles show for a while after the selection changes or a
  /// handle is used, then fade (see [_showHandles]).
  bool _handlesShown = false;
  Timer? _handlesTimer;

  /// When a bar was last tapped. The corners appear with that tap's
  /// selection, and their targets cover much of a narrow bar, so the second
  /// tap of a double-tap would land on one and grow the selection; within
  /// [kDoubleTapTimeout] a corner tap is passed on as a bar tap instead.
  DateTime? _lastBarTap;

  EngravedScore? _score;
  ScalableImage? _image;
  String? _error;

  // The width the current [_score] was engraved for; re-engrave when the
  // available width crosses a bucket boundary (reflow on rotation/resize).
  // Assigned only after a successful engrave, so it always describes [_score].
  double _engravedWidth = 0;

  /// The size the current [_score] was engraved at. Compared against the live
  /// provider to decide whether a re-engrave is needed.
  StaffSize? _engravedSize;

  /// The effective `spacingSystem` the current [_score] was engraved with; a
  /// change means a re-engrave (and a re-calibration, since it moves the system
  /// height).
  int? _engravedSpacingUnits;

  /// The width the last build laid out at — the single denominator for the
  /// viewBox→screen scale, shared by the painters, hit testing and autoscroll.
  double _layoutWidth = 0;

  /// The height the last build drew the page at (`viewBox.height × _scale`),
  /// reported through [StaffViewVerovio.onContentHeight] when it changes.
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

  // `[open]` timing: widget start → first paint, and engraves spent on it.
  final _openSw = Stopwatch()..start();
  final _openEngraves = VerovioEngraver.engraveCount;
  bool _openLogged = false;
  bool _engraving = false;
  _EngraveRequest? _pending; // latest-wins queue

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
    if (widget.selection != old.selection) {
      if (widget.selection == null) {
        _hideHandles(rebuild: false);
      } else {
        _showHandles(rebuild: false);
      }
    }
    // Nothing a holding widget says is final; the next one is compared with
    // it, and whatever really changed is caught then.
    if (widget.holding) return;
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
        old.sectionLayout != widget.sectionLayout ||
        old.printedLines != widget.printedLines ||
        !mapEquals(old.sectionLabels, widget.sectionLabels) ||
        old.showNoteNames != widget.showNoteNames ||
        !listEquals(old.tabFingerLabels, widget.tabFingerLabels)) {
      _reservesAnnotationRoom = scoreReservesAnnotationRoom(widget.musicXml);
      _engravedWidth = 0;
      _calibratedFor = null;
      _calibrations.clear();
      _naturalBySpacing.clear();
    }
    // The tint is a re-parse of the engrave already on screen. (A re-engrave
    // kicked above re-tints on its own, through [_publish].)
    final score = _score;
    if (score != null &&
        (old.colourNoteheads != widget.colourNoteheads ||
            (widget.colourNoteheads &&
                !listEquals(old.noteNames, widget.noteNames)))) {
      _image = _imageFor(score);
    }
    if (widget.scrollNav != null && widget.scrollNav != old.scrollNav) {
      _scrollToMeasureIndex(widget.scrollNav!.index);
    }
  }

  @override
  void dispose() {
    _handlesTimer?.cancel();
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
  ///
  /// The note spacing ([_spacingLinear]) is in it too: it changes every bar's
  /// width, which is the very thing the calibration measures.
  String _calibrationKeyFor(int spacingUnits) =>
      '${widget.musicXml.hashCode}|${widget.tabMode}|$spacingUnits'
      '|${widget.showNoteNames}|$_spacingLinear';

  /// Natural (unjustified) width of every engraved measure in MEI units, for
  /// the section layout — measured once per calibration from a one-line
  /// engrave. Keyed like the calibration it belongs to.
  List<double> _naturalWidths = const [];

  /// [_naturalWidthsAt]'s results, by calibration key. Fit reads the piece at
  /// two spacings to decide how far to squeeze, and the section layout reads
  /// the one it engraves at, so one engrave each serves all of them.
  final Map<String, List<double>> _naturalBySpacing = {};

  /// Every calibration this score has had, by key, so that moving between
  /// note spacings restores one rather than re-measuring it. Fit calibrates at
  /// the default spacing and then at the one it squeezes to, on every pass;
  /// starting either afresh each time would throw away what refinement learned
  /// and reset its counter, and the refinement would never stop.
  final Map<String, _Calibration> _calibrations = {};

  /// Whether the current request is Fit on a piece too long for one screen
  /// (see [_fitSpacing]); published with the engrave, to [fitTooLongProvider].
  bool _fitTooLong = false;

  /// The note spacing every engrave of the current request uses: the size's
  /// own ([spacingLinearForSize]), or what Fit squeezed to ([_fitSpacing]).
  double _spacingLinear = spacingLinearDefault;

  /// The annotated view: fingering chips and note names need room across the
  /// line, so the spacing never goes below [spacingLinearMinAnnotated].
  bool get _annotated =>
      widget.fingeringAnnotations.isNotEmpty || widget.showNoteNames;

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
    // A re-engrave keeps the old score up until the new one lands, which can
    // take seconds; [build] dims it and shows a spinner meanwhile, so a size
    // or layout change visibly registers.
    if (mounted && _score != null) setState(() {});
    try {
      while (mounted && _pending != null) {
        final req = _pending!;
        _pending = null;
        await _engrave(req);
      }
    } finally {
      _engraving = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _engrave(_EngraveRequest req) async {
    final seq = ++_engraveSeq;
    try {
      // 0. Note spacing: the size's own. Fit starts from the default and may
      //    squeeze below it once it has seen how the piece lays out.
      _spacingLinear = widget.zoomable
          ? spacingLinearForSize(req.size, annotated: _annotated)
          : spacingLinearDefault;
      var cal = await _calibrate(req, seq);
      if (cal.stale) return;
      var probe = cal.probe;

      // 1b. Fit: tighten the note spacing until the plan fills the screen.
      int? fitTarget;
      _fitTooLong = false;
      if (req.size == StaffSize.fit && widget.zoomable && !widget.printedLines) {
        final fit = await _fitSpacing(req, seq);
        if (fit == null) return; // stale
        fitTarget = fit.flowTarget;
        _fitTooLong = fit.tooLong;
        if (fit.spacing != _spacingLinear) {
          _spacingLinear = fit.spacing;
          cal = await _calibrate(req, seq);
          if (cal.stale) return;
          probe = cal.probe;
        }
      }

      if (req.sections) {
        await _engraveSections(req, seq);
        return;
      }

      // 2. Resolve the size to a measures-per-line target and solve for
      //    Verovio's scale. Fit never packs more bars than Small would.
      final target = req.size == StaffSize.fit
          ? fitTarget ?? _flowFitTarget(req)
          : measuresPerLineForSize(
              size: req.size,
              widthPx: req.widthPx,
              unitsPerMeasure: _unitsPerMeasure,
              shortestSidePx: req.shortestSidePx,
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
          'size=${req.size.name} n=$target sl=$_spacingLinear '
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
          _reserveSpacingUnits == 0 &&
          _reservePageMarginUnits == 0;
      var score = reusable
          ? probe
          : await _engraveAt(
              req.widthPx,
              scale,
              spacingSystem: (req.spacingUnits + _reserveSpacingUnits).clamp(
                0,
                verovioSpacingSystemMax,
              ),
              pageMarginTopReserve: _reservePageMarginUnits,
            );
      if (!mounted || seq != _engraveSeq) return;

      // 3b. Auto mode's own dead-margin fix: freeze whatever break points
      //     Verovio's `breaks: 'auto'` engrave above just chose, hiding the
      //     preamble at each. Skipped for previews (zoomable: false —
      //     measureMap is empty there, and a 1-2 bar preview has nothing to
      //     freeze anyway). One more full engrave, so only worth it when
      //     there is more than one system to fix.
      if (widget.zoomable && !widget.measureMap.hasSplits) {
        final breakNumbers = <int>{};
        for (var i = 1; i < score.measureLine.length; i++) {
          if (i >= widget.measureMap.length) break;
          if (score.measureLine[i] != score.measureLine[i - 1]) {
            breakNumbers.add(widget.measureMap.numberAt(i));
          }
        }
        if (breakNumbers.isNotEmpty) {
          final frozenXml = freezeSystemBreaks(widget.musicXml, breakNumbers);
          score = await _engraveAt(
            req.widthPx,
            scale,
            spacingSystem: (req.spacingUnits + _reserveSpacingUnits).clamp(
              0,
              verovioSpacingSystemMax,
            ),
            pageMarginTopReserve: _reservePageMarginUnits,
            breaks: 'encoded',
            musicXmlOverride: frozenXml,
          );
          if (!mounted || seq != _engraveSeq) return;
        }
      }

      _publish(score, req);

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
        setState(() => _error = '$e');
      }
    }
  }

  /// 1. Calibrate, at [_spacingLinear]. unitsPerMeasure is a property of the
  /// piece (at a given note spacing), invariant in both scale and width, so one
  /// probe engrave serves every later size. The probe uses the pre-zoom option
  /// set, so an un-zoomed piece reuses the cache entry it always had.
  ///
  /// [stale]: a newer request superseded this one while it waited.
  Future<({bool stale, EngravedScore? probe})> _calibrate(
    _EngraveRequest req,
    int seq,
  ) async {
    EngravedScore? probe;
    final key = _calibrationKeyFor(req.spacingUnits);
    if (_calibratedFor != key) {
      // Keep what the one being left learned, and come back to it later.
      final leaving = _calibratedFor;
      if (leaving != null) _calibrations[leaving] = _saveCalibration();
      final known = _calibrations[key];
      if (known != null) {
        _restoreCalibration(known);
        _calibratedFor = key;
        return (stale: false, probe: null);
      }
    }
    if (_calibratedFor != key) {
      // BARE — the staff-spacing preference and Verovio's own page margin,
      // with no annotation reserve. The probe's job now includes measuring how
      // much room this score's layout already leaves, and it cannot measure
      // that through a reserve it was given up front.
      probe = await _engraveAt(
        req.widthPx,
        staffScaleProbe,
        spacingSystem: req.spacingUnits,
      );
      if (!mounted || seq != _engraveSeq) return (stale: true, probe: null);
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
          wantSpaces: annotationWantSpaces(
            probe,
            staffScaleProbe,
            withNameRow: widget.showNoteNames,
          ),
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
    return (stale: false, probe: probe);
  }

  _Calibration _saveCalibration() => (
        unitsPerMeasure: _unitsPerMeasure,
        systemHeightPx: _systemHeightPx,
        measureCount: _measureCount,
        refinements: _refinements,
        reserveSpacingUnits: _reserveSpacingUnits,
        reservePageMarginUnits: _reservePageMarginUnits,
      );

  void _restoreCalibration(_Calibration c) {
    _unitsPerMeasure = c.unitsPerMeasure;
    _systemHeightPx = c.systemHeightPx;
    _measureCount = c.measureCount;
    _refinements = c.refinements;
    _reserveSpacingUnits = c.reserveSpacingUnits;
    _reservePageMarginUnits = c.reservePageMarginUnits;
  }

  /// Every engraved measure's natural (unjustified) width in MEI units at note
  /// spacing [spacing], from one engrave of the whole piece on a single line.
  /// Null when a newer request superseded this one.
  Future<List<double>?> _naturalWidthsAt(
    double spacing,
    _EngraveRequest req,
    int seq,
  ) async {
    final was = _spacingLinear;
    _spacingLinear = spacing;
    final key = _calibrationKeyFor(req.spacingUnits);
    try {
      final known = _naturalBySpacing[key];
      if (known != null) return known;
      final line = await _engraveAt(
        sectionNaturalLineWidthPx,
        staffScaleProbe,
        spacingSystem: req.spacingUnits,
        breaks: 'none',
      );
      if (!mounted || seq != _engraveSeq) return null;
      return _naturalBySpacing[key] = [
        for (final m in line.measures) m.rect.width * 100 / staffScaleProbe,
      ];
    } finally {
      _spacingLinear = was;
    }
  }

  /// Fit's measures-per-line in the free flow: the whole piece on one screen,
  /// never more bars a line than Small would put there.
  int _flowFitTarget(_EngraveRequest req) => math.min(
        autoMeasuresPerLine(
          widthPx: req.widthPx,
          viewportHeightPx: req.viewportHeightPx,
          shortestSidePx: req.shortestSidePx,
          unitsPerMeasure: _unitsPerMeasure,
          systemHeightPx: _systemHeightPx,
          measureCount: _measureCount,
        ),
        measuresPerLineForSize(
          size: StaffSize.small,
          widthPx: req.widthPx,
          unitsPerMeasure: _unitsPerMeasure,
          shortestSidePx: req.shortestSidePx,
        ),
      );

  /// Fraction of Fit's height budget the squeeze aims for. A little under
  /// the budget, because the spacing is interpolated: aiming at the budget
  /// itself would sometimes land just over it, and the section layout's search
  /// would then fall back a whole plan, to smaller notes than no squeeze at all.
  static const _fitSqueezeAim = 0.95;

  /// The note spacing Fit engraves at, and for the free flow the bars a line
  /// ([fitSpacingLinear]). Two layouts are weighed: the one that fits at the
  /// default spacing, squeezed until it fills the screen, and the next bigger
  /// one, which doesn't fit, loosened until it does. Whichever ends up with
  /// the bigger notes wins. On Lightly Row in the flow that is the difference
  /// between 4 bars a line squeezed (half the screen) and 3 loosened (full).
  ///
  /// Costs two one-line engraves of the piece, at the default spacing and the
  /// tightest allowed, both cached; none at all when the layout already fills
  /// the screen.
  ///
  /// [flowTarget] is the free flow's measures-per-line, held through the new
  /// spacing: re-solved there, the auto-fit would pick its count afresh and
  /// undo the choice. Null when stale.
  Future<({double spacing, int? flowTarget, bool tooLong})?> _fitSpacing(
    _EngraveRequest req,
    int seq,
  ) async {
    final none = (spacing: _spacingLinear, flowTarget: null, tooLong: false);
    final budget = req.viewportHeightPx * staffAutoFillFraction;
    if (budget <= 0 || _systemHeightPx <= 0) return none;
    final atDefault = await _naturalWidthsAt(_spacingLinear, req, seq);
    if (atDefault == null) return null;

    // Each layout's height and scale at the default spacing, the one that fits
    // first. A section plan's scale is its own; the flow's is solved from n.
    final candidates = <({double height, double scale, int? n})>[];
    if (req.sections) {
      final c = sectionFitCandidates(
        musicXml: widget.musicXml,
        naturalWidths: atDefault,
        widthPx: req.widthPx,
        viewportHeightPx: req.viewportHeightPx,
        systemHeightPx: _systemHeightPx,
        minScale: staffScaleForSize(StaffSize.small, req.shortestSidePx),
        sectionLabels: widget.sectionLabels,
      );
      for (final plan in [c.fits, ?c.bigger]) {
        candidates.add((
          height: plan.lines * _systemHeightPx * plan.scale / staffScaleProbe,
          scale: plan.scale,
          n: null,
        ));
      }
    } else {
      final n0 = _flowFitTarget(req);
      for (final n in [n0, if (n0 > measuresPerLineMin) n0 - 1]) {
        candidates.add((
          height: predictedHeightPx(
            widthPx: req.widthPx,
            unitsPerMeasure: _unitsPerMeasure,
            systemHeightPx: _systemHeightPx,
            measureCount: _measureCount,
            n: n,
          ),
          scale: scaleFor(
            widthPx: req.widthPx,
            unitsPerMeasure: _unitsPerMeasure,
            n: n,
          ),
          n: n,
        ));
      }
    }
    final aim = budget * _fitSqueezeAim;
    // Already full: nothing to squeeze, and anything bigger can only overflow.
    // Too long for one screen even at Small's note size: then Fit is Small,
    // spacing included, so the piece scrolls as little as it can. The flow
    // target is left to be solved afresh at that spacing (Small's count).
    if (candidates.first.height > budget) {
      return (
        spacing: spacingLinearForSize(StaffSize.small, annotated: _annotated),
        flowTarget: null,
        tooLong: true,
      );
    }
    // Already full: nothing to squeeze, and anything bigger can only overflow.
    if (candidates.first.height >= aim) {
      return (
        spacing: _spacingLinear,
        flowTarget: candidates.first.n,
        tooLong: false,
      );
    }

    final minSpacing =
        _annotated ? spacingLinearMinAnnotated : spacingLinearMin;
    final atMin = await _naturalWidthsAt(minSpacing, req, seq);
    if (atMin == null) return null;
    double sum(List<double> w) => w.fold(0.0, (a, b) => a + b);
    final w0 = sum(atDefault), wMin = sum(atMin);

    ({double spacing, int? flowTarget, bool tooLong})? best;
    var bestScale = 0.0;
    for (final c in candidates) {
      final spacing = fitSpacingLinear(
        predictedHeightPx: c.height,
        budgetPx: aim,
        widthAtDefault: w0,
        widthAtMin: wMin,
        minSpacing: minSpacing,
      );
      if (spacing == null) continue; // too big even at the widest spacing
      final width = naturalWidthAtSpacing(spacing,
          widthAtDefault: w0, widthAtMin: wMin, minSpacing: minSpacing);
      final scale = width > 0 ? c.scale * w0 / width : c.scale;
      // Whatever the spacing model says, a layout that would still run past
      // the budget is not a fit. (With no usable measurement the model leaves
      // every layout at its default size, and the bigger one would otherwise
      // win on scale alone: 2 bars a line, nearly two screens tall.)
      if (c.height * scale / c.scale > budget) continue;
      if (VerovioEngraver.debugLogging) {
        debugPrint('[fit] candidate n=${c.n} height=${c.height.round()} '
            'aim=${aim.round()} width ${w0.round()}→min ${wMin.round()} '
            'spacing=$spacing scale ${c.scale.toStringAsFixed(1)}'
            '→${scale.toStringAsFixed(1)}');
      }
      if (scale > bestScale) {
        bestScale = scale;
        best = (spacing: spacing, flowTarget: c.n, tooLong: false);
      }
    }
    return best ??
        (
          spacing: _spacingLinear,
          flowTarget: candidates.first.n,
          tooLong: false,
        );
  }

  /// [score]'s SVG as a drawable, with the notehead tint applied if it's on.
  ///
  /// jovial parse is synchronous and fast (a few ms); currentColor resolves
  /// Verovio's CSS stroke:currentColor on staff lines/stems/beams.
  ScalableImage _imageFor(EngravedScore score) => ScalableImage.fromSvgString(
        widget.colourNoteheads
            ? VerovioEngraver.colourNoteheads(
                score.svg, noteheadFillsFor(score, widget.noteNames))
            : score.svg,
        currentColor: Colors.black,
        warnF: (_) {},
      );

  /// Puts a finished engrave on screen and reports what it achieved.
  void _publish(EngravedScore score, _EngraveRequest req) {
    final imageSw = Stopwatch()..start();
    final image = _imageFor(score);
    if (VerovioEngraver.timingLogging && widget.zoomable && !_openLogged) {
      _openLogged = true;
      debugPrint('[open] tap→paint=${VerovioEngraver.openClock.elapsedMilliseconds}ms '
          'widget→paint=${_openSw.elapsedMilliseconds}ms '
          'engraves=${VerovioEngraver.engraveCount - _openEngraves} '
          'jovial=${imageSw.elapsedMilliseconds}ms');
    }
    setState(() {
      _score = score;
      _image = image;
      _error = null;
      _engravedWidth = req.widthPx;
      _engravedSize = req.size;
      _engravedSpacingUnits = req.spacingUnits;
    });
    // Report what Verovio actually did — its break points are musical, so a
    // dense bar can land one short of the target.
    // Only the whole-piece views speak for it; a one-bar preview would
    // otherwise overwrite the readout with its own count.
    if (widget.zoomable) {
      ref.read(fitTooLongProvider.notifier).state =
          req.size == StaffSize.fit && _fitTooLong;
      ref.read(effectiveMeasuresPerLineProvider.notifier).state =
          measuresPerLineOf(score.measureLine);
    }
    _onHighlight(); // re-place the cursor on the fresh layout
  }

  /// The section layout's engrave (`StaffViewVerovio.sectionLayout`): the xml
  /// already breaks before every section start, so what is left to choose is
  /// how each section fills its lines, and the scale.
  ///
  /// The smallest acceptable staff size (`minStaffScaleFor`) fixes how wide a
  /// line may be; each section then takes the fewest lines that fit inside
  /// that, cut where the lines come out most even (`planSectionLines`), and
  /// the scale is solved so the widest planned line fills the width. Widths
  /// come from one engrave of the whole piece on a single unjustified line, so
  /// a split bar's half slices and a wide bar of words are each measured as
  /// they are rather than averaged.
  ///
  /// No refinement pass: the breaks are encoded, so Verovio cannot pack more
  /// onto a line than planned, and there is no per-measure average to tighten.
  Future<void> _engraveSections(_EngraveRequest req, int seq) async {
    final spacing = (req.spacingUnits + _reserveSpacingUnits).clamp(
      0,
      verovioSpacingSystemMax,
    );
    final widths = await _naturalWidthsAt(_spacingLinear, req, seq);
    if (widths == null) return;
    _naturalWidths = widths;

    // A fixed size is a floor on the note size: each section takes the fewest
    // lines that keep its notes at least that big. Fit searches for the
    // biggest floor at which the whole piece is on one screen, Small at worst.
    final solved = widget.printedLines
        ? solveSectionLayout(
            musicXml: widget.musicXml,
            naturalWidths: _naturalWidths,
            widthPx: req.widthPx,
            minScale: staffScaleMin,
            linesPerSection: 1,
          )
        : req.size == StaffSize.fit
        ? solveSectionLayoutToFit(
            musicXml: widget.musicXml,
            naturalWidths: _naturalWidths,
            widthPx: req.widthPx,
            viewportHeightPx: req.viewportHeightPx,
            systemHeightPx: _systemHeightPx,
            minScale: staffScaleForSize(StaffSize.small, req.shortestSidePx),
            sectionLabels: widget.sectionLabels,
          )
        : solveSectionLayout(
            musicXml: widget.musicXml,
            naturalWidths: _naturalWidths,
            widthPx: req.widthPx,
            minScale: staffScaleForSize(req.size, req.shortestSidePx),
            sectionLabels: widget.sectionLabels,
          );
    final scale = solved.scale;
    final lines = solved.lines;
    if (VerovioEngraver.debugLogging) {
      debugPrint(
        '[sections] w=${req.widthPx.round()} bars=${_naturalWidths.length} '
        'segments=${lines - solved.breaks.length} lines=$lines '
        'widest=${solved.widestUnits.round()}u '
        'floor=${minStaffScaleFor(req.shortestSidePx).toStringAsFixed(1)} '
        'scale=${scale.toStringAsFixed(1)} sl=$_spacingLinear breaks=${(solved.breaks.toList()..sort())} '
        'minLastJust=${solved.minLastJustification}',
      );
    }
    final score = await _engraveAt(
      req.widthPx,
      scale,
      spacingSystem: spacing,
      pageMarginTopReserve: _reservePageMarginUnits,
      breaks: 'encoded',
      musicXmlOverride: solved.xml,
      minLastJustification: solved.minLastJustification,
    );
    if (!mounted || seq != _engraveSeq) return;
    _publish(score, req);
    if (widget.zoomable) {
      ref.read(effectiveLinesPerSectionProvider.notifier).state =
          solved.maxLines;
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

  Future<EngravedScore> _engraveAt(
    double widthPx,
    double scale, {
    required int spacingSystem,
    int pageMarginTopReserve = 0,
    String breaks = 'auto',
    String? musicXmlOverride,
    double? minLastJustification,
  }) {
    return VerovioEngraver.instance.engrave(
      musicXmlOverride ?? widget.musicXml,
      widthPx: widthPx,
      scale: scale,
      spacingSystem: spacingSystem,
      breaks: breaks,
      // System 0's rows come out of the page's top margin, there being no
      // system above it to borrow from. Passed in rather than derived here: the
      // probe engraves bare so it can MEASURE what the margin already gives,
      // and only the real engrave carries the reserve that measurement asked
      // for. See [annotationReserveFor].
      pageMarginTop: (verovioPageMarginTopDefault + pageMarginTopReserve).clamp(
        0,
        verovioPageMarginTopMax,
      ),
      // mnumInterval is left at its 0 default, which still numbers each
      // system's first bar; VerovioEngraver.stripMeasureNumbers cuts those out.
      // They were drawn into the same whitespace the annotation lanes use, so
      // they landed on top of the fingering row.
      tabMode: widget.tabMode,
      tabFingerLabels: widget.tabFingerLabels,
      stripRepeatClefs: !widget.tabMode,
      spacingLinear:
          _spacingLinear == spacingLinearDefault ? null : _spacingLinear,
      minLastJustification: minLastJustification,
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
    // A moved repeat's tail is drawn on its lead-in on the pass that jumps back.
    final at = widget.measureMap
        .locatePlayed(ev.measureNumber, ev.noteIndex, ev.performanceIndex);
    if (at == null) return null;
    return score.noteAt(at.index, at.note);
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
  /// system sits near the top.
  void _autoScrollTo(Rect rectVb) {
    if (!_scrollController.hasClients) return;
    final scale = _scale;
    final top = rectVb.top * scale;
    final bottom = rectVb.bottom * scale;
    final viewport = _scrollController.position.viewportDimension;
    final offset = _scrollController.offset;
    final visibleTop = offset;
    // Less whatever sits over the view's bottom edge (the phone's play tray),
    // so the turn comes before the cursor slides under it, not after.
    final visibleBottom =
        offset + viewport - ref.read(staffViewBottomInsetProvider);
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

  // ── Taps ───────────────────────────────────────────────────────────────

  /// The model measure number at [local] (page coordinates, screen px), or
  /// null. See [measureIndexAtPoint].
  int? _measureAt(Offset local) {
    final score = _score;
    if (score == null) return null;
    final i = measureIndexAtPoint(score, local / _scale);
    if (i == null || i < 0 || i >= widget.measureMap.length) return null;
    return widget.measureMap.numberAt(i);
  }

  int? _measureAtGlobal(Offset global) {
    final box = _pageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return _measureAt(box.globalToLocal(global));
  }

  void _onTapUp(Offset local) {
    _lastBarTap = DateTime.now();
    final m = _measureAt(local);
    if (m != null) widget.onMeasureTapped?.call(m);
  }

  /// Shows the end handles, and fades them [selectionHandleLinger] after
  /// the last reason to: they're for adjusting a selection just made, not
  /// furniture over the music.
  void _showHandles({bool rebuild = true}) {
    _handlesTimer?.cancel();
    _handlesTimer = Timer(selectionHandleLinger, () {
      if (mounted) setState(() => _handlesShown = false);
    });
    if (rebuild) {
      setState(() => _handlesShown = true);
    } else {
      _handlesShown = true;
    }
  }

  void _hideHandles({bool rebuild = true}) {
    _handlesTimer?.cancel();
    if (rebuild) {
      setState(() => _handlesShown = false);
    } else {
      _handlesShown = false;
    }
  }

  /// The selection's end handles: thin L-shaped marks at its outer
  /// corners, like a crop frame's, two at each end. A tap on either mark at
  /// an end widens the selection there by a bar; a drag puts that end on
  /// any bar, either way.
  ///
  /// No tap to narrow: a fresh tap on a bar and a few taps on the corner
  /// make any range, and one mark per corner stays out of the music's way.
  /// The marks sit just inside the shaded band's corners, as part of the
  /// selection rather than laid beside it. Each takes touches across a full
  /// [selectionHandleTarget] square, reaching into the selection.
  List<Widget> _selectionHandles(
      EngravedScore score, double scale, double width, ThemeData theme) {
    final sel = widget.selection!;
    final nudge = widget.onNudgeSelection!;
    final r = widget.measureMap.range(
        sel.startMeasure, sel.startNote, sel.endMeasure, sel.endNote,
        startPerf: sel.startPerf);
    if (r == null) return const [];
    final rows = _rangeRowRects(score, scale, r.startMeasureIndex,
        r.startNote, r.endMeasureIndex, r.endNote);
    if (rows.isEmpty) return const [];
    final color = theme.colorScheme.primary.withValues(alpha: 0.45);
    final active = _handlesShown && !_dragging;
    const inset = selectionCornerInset, half = selectionHandleTarget / 2;

    Widget corner(Rect row, bool atStart, bool top) {
      final x = atStart ? row.left + inset : row.right - inset;
      final y = top ? row.top + inset : row.bottom - inset;
      // The target reaches INTO the selection from the corner, so the mark
      // sits at its outer corner; kept on the page.
      final cx = (x + (atStart ? half - 4 : -half + 4))
          .clamp(half, math.max(half, width - half));
      final cy = y + (top ? half - 4 : -half + 4);
      final end = atStart ? 'start' : 'end';
      return Positioned(
        left: cx - half,
        top: cy - half,
        width: selectionHandleTarget,
        height: selectionHandleTarget,
        child: _CornerHandle(
          key: ValueKey('sel_${end}_${top ? 'top' : 'bottom'}'),
          corner: Offset(x - (cx - half), y - (cy - half)),
          pointsRight: atStart,
          pointsDown: top,
          color: color,
          label: atStart ? 'Start one bar earlier' : 'End one bar later',
          onTap: (global) {
            final last = _lastBarTap;
            if (last != null &&
                DateTime.now().difference(last) < kDoubleTapTimeout) {
              _lastBarTap = null;
              final m = _measureAtGlobal(global);
              if (m != null) widget.onMeasureTapped?.call(m);
              return;
            }
            nudge(atStart, atStart ? -1 : 1);
            _showHandles();
          },
          onDragTo: (global) {
            final m = _measureAtGlobal(global);
            if (m != null) widget.onMoveSelectionEdge?.call(atStart, m);
            _showHandles();
          },
        ),
      );
    }

    return [
      Positioned.fill(
        child: IgnorePointer(
          ignoring: !active,
          child: AnimatedOpacity(
            opacity: active ? 1 : 0,
            duration: const Duration(milliseconds: 350),
            child: Stack(clipBehavior: Clip.none, children: [
              corner(rows.first, true, true),
              corner(rows.first, true, false),
              corner(rows.last, false, true),
              corner(rows.last, false, false),
            ]),
          ),
        ),
      ),
    ];
  }

  void _setDragging(bool on) {
    setState(() => _dragging = on);
    widget.onMeasureDragging?.call(on);
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Playing hides the end handles; stopping brings them back for a while,
    // the moment one is most likely wanted (that loop was a bar short).
    if (widget.onNudgeSelection != null) {
      ref.listen(activePlaybackStateProvider, (prev, next) {
        final playing = next.valueOrNull == PlaybackState.playing;
        final was = prev?.valueOrNull == PlaybackState.playing;
        if (playing && !was) {
          _hideHandles();
        } else if (was && !playing && widget.selection != null) {
          _showHandles();
        }
      });
    }
    if (_error != null) {
      return Center(
        child: Text('Staff view error: $_error', textAlign: TextAlign.center),
      );
    }
    // The previews (measure editor, palette) opt out of the piece's size so it
    // doesn't shrink their single bar: they always fit their box.
    // Like original scan's size is fixed by its widest printed line.
    final size = widget.zoomable && !widget.printedLines
        ? ref.watch(staffSizeProvider)
        : StaffSize.fit;
    final screen = MediaQuery.sizeOf(context);
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
            size != _engravedSize ||
            spacingUnits != _engravedSpacingUnits;
        if (width > 0 && !widget.holding && stale()) {
          // Scheduled post-frame so we don't setState during layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !widget.holding && stale()) {
              _request((
                widthPx: width,
                viewportHeightPx: viewportHeight,
                shortestSidePx: shortestSide,
                size: size,
                spacingUnits: spacingUnits,
                sections: widget.sectionLayout,
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
        if (renderH != _renderHeight && widget.onContentHeight != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onContentHeight?.call(renderH);
          });
        }
        _renderHeight = renderH;
        final page = SingleChildScrollView(
          controller: _scrollController,
          // Room past the last system to scroll it clear of the play tray.
          // Not for the previews, which sit nowhere near the tray.
          padding: EdgeInsets.only(
              bottom: widget.zoomable
                  ? ref.watch(notationBottomClearanceProvider)
                  : 0),
          // On tap UP, not down: a press that turns into a scroll is the
          // scroll's, and must not move the selection on its way.
          child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _onTapUp(d.localPosition),
                child: SizedBox(
                  key: _pageKey,
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
                              measureMap: widget.measureMap,
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
                              withNameRow: widget.showNoteNames,
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
                              noteNames: widget.showNoteNames
                                  ? widget.noteNames
                                  : const [],
                              withNameRow: widget.showNoteNames,
                              keySignature: widget.keySignatureLabel,
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _EndingPainter(
                              score: score,
                              scale: scale,
                              withNameRow: widget.showNoteNames,
                            ),
                          ),
                        ),
                      ),
                      // Topmost, so a chip or bracket can't hide the number.
                      if (widget.selection != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _MeasureNumberPainter(
                                score: score,
                                scale: scale,
                                measureMap: widget.measureMap,
                                selection: widget.selection!,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      if (widget.onNudgeSelection != null &&
                          widget.selection != null)
                        ..._selectionHandles(score, scale, width, theme),
                    ],
                  ),
                ),
          ),
        );
        // Re-engraving: the stale score dimmed, with a spinner over it. Only
        // the whole-piece views; a preview's box is too small to need it.
        final busy = (_engraving || widget.holding) && widget.zoomable;
        return Stack(
          children: [
            AnimatedOpacity(
              opacity: busy ? 0.35 : 1,
              duration: const Duration(milliseconds: 150),
              child: MeasureDragSelect(
                controller: _scrollController,
                enabled: widget.onMeasureRange != null,
                measureAt: _measureAtGlobal,
                onRange: (a, b) => widget.onMeasureRange?.call(a, b),
                onDragging: _setDragging,
                bottomInset: widget.zoomable
                    ? ref.watch(staffViewBottomInsetProvider)
                    : 0,
                child: page,
              ),
            ),
            // At the bottom, just above the play tray: the size panel opens
            // over the top of the score, so a spinner there was hidden behind
            // the very panel whose tap started the engrave.
            if (busy)
              Positioned(
                left: 0,
                right: 0,
                bottom: ref.watch(notationBottomClearanceProvider) + 16,
                child: Center(
                  key: const ValueKey('staff_reengraving'),
                  child: Material(
                    elevation: 3,
                    color: theme.colorScheme.surfaceContainerHigh,
                    shape: const StadiumBorder(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator.adaptive(
                              strokeWidth: 2.5,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Laying out the music…',
                            style: theme.textTheme.labelLarge,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static int _bucket(double w) => (w / 48).round();
}

/// Paints an engraved score the way [StaffViewVerovio] stacks it — section
/// washes, the notation, the fingering lane, the chord lane — onto any canvas
/// [size] wide, at [scale] (viewBox → canvas). Print draws its pages with this
/// (`score_printer.dart`), so paper and screen share one set of painters.
///
/// Only the static layers: selection, flags, the cursor and the count-in are
/// the screen's alone.
void paintStaffScore(
  Canvas canvas,
  Size size, {
  required EngravedScore score,
  required ScalableImage image,
  required double scale,
  List<SectionTintRegion> sectionTints = const [],
  List<ChordRunRegion> chordRuns = const [],
  List<FingeringAnnotation> fingeringAnnotations = const [],
  List<StringRunRegion> stringRuns = const [],
  StringColourStyle stringColourStyle = StringColourStyle.chips,
  bool monochromeRules = false,
  List<NoteNameLabel> noteNames = const [],
  bool showNoteNames = false,
}) {
  _UnderlayPainter(score: score, scale: scale, sectionTints: sectionTints)
      .paint(canvas, size);
  canvas.save();
  // What `ScalableImageWidget(fit: BoxFit.fitWidth)` does on screen.
  final fit = size.width / image.viewport.width;
  canvas.scale(fit, fit);
  image.paint(canvas);
  canvas.restore();
  _FingeringLanePainter(
    score: score,
    scale: scale,
    annotations: fingeringAnnotations,
    stringRuns: stringRuns,
    style: stringColourStyle,
    monochromeRules: monochromeRules,
    withNameRow: showNoteNames,
  ).paint(canvas, size);
  _ChordLanePainter(
    score: score,
    scale: scale,
    runs: chordRuns,
    noteNames: showNoteNames ? noteNames : const [],
    withNameRow: showNoteNames,
  ).paint(canvas, size);
  _EndingPainter(score: score, scale: scale, withNameRow: showNoteNames)
      .paint(canvas, size);
}

/// SVG note id → notehead fill (`#rrggbb`) for every entry in [noteNames] with a
/// known string — the map [VerovioEngraver.colourNoteheads] takes. The colour is
/// [ViolinStringPalette.rule], the variant dark enough to read on white (the
/// chip yellow for E would vanish on a notehead).
Map<String, String> noteheadFillsFor(
  EngravedScore score,
  List<NoteNameLabel> noteNames,
) {
  if (noteNames.isEmpty) return const {};
  final ids = <(int, int), String>{
    for (final n in score.notes) (n.measureIndex, n.noteIndex): n.id,
  };
  final out = <String, String>{};
  for (final n in noteNames) {
    final string = n.string;
    if (string == null) continue;
    final id = ids[(n.measureIndex, n.noteIndex)];
    if (id == null) continue;
    final rgb = ViolinStringPalette.rule(string).toARGB32() & 0xFFFFFF;
    out[id] = '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }
  return out;
}

/// Drawn (viewBox→screen scaled) rects for an engraved range, one per system
/// line — shared by the section wash and the selection, so a selection of a
/// section covers exactly what its tint does. Measures are unioned
/// horizontally within a line; the line's TILED band (from the engraving)
/// sets the height so adjacent lines neither overlap nor gap; the first
/// measure's left and a partial last measure's right are clipped to notes
/// (mid-measure section edges). The range is [EngravedMeasureMap.range]'s
/// shape: [endNote] is exclusive, `-1` for the whole of [endIndex].
List<Rect> _rangeRowRects(EngravedScore score, double scale, int startIndex,
    int startNote, int endIndex, int endNote) {
  final r = (
    startMeasureIndex: startIndex,
    startNote: startNote,
    endMeasureIndex: endIndex,
    endNote: endNote,
  );
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
      Rect.fromLTRB(s.left * scale, s.top * scale, s.right * scale,
          s.bottom * scale),
  ];
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

  /// White left between two different sections' washes, in logical pixels,
  /// so back-to-back sections of one color (A A) still read as two.
  static const sectionGap = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (sectionTints.isEmpty) return;
    final rects = [for (final region in sectionTints) _regionRowRects(region)];
    for (var i = 0; i < sectionTints.length; i++) {
      final color = _parseHex(sectionTints[i].color).withValues(alpha: 0.10);
      final others = [
        for (var j = 0; j < rects.length; j++)
          if (j != i) ...rects[j],
      ];
      for (final rect in rects[i]) {
        canvas.drawRect(_insetWhereTouching(rect, others), Paint()..color = color);
      }
    }
  }

  /// [rect] pulled back by half the gap on each side that meets one of
  /// [others] — a line above or below, or a mid-line section edge — and left
  /// alone where it meets the next line of its own section.
  static Rect _insetWhereTouching(Rect rect, List<Rect> others) {
    const eps = 0.5, half = sectionGap / 2;
    bool overlapsX(Rect o) => o.left < rect.right && o.right > rect.left;
    bool overlapsY(Rect o) => o.top < rect.bottom && o.bottom > rect.top;
    var r = rect;
    for (final o in others) {
      if ((o.bottom - rect.top).abs() < eps && overlapsX(o)) {
        r = Rect.fromLTRB(r.left, rect.top + half, r.right, r.bottom);
      }
      if ((o.top - rect.bottom).abs() < eps && overlapsX(o)) {
        r = Rect.fromLTRB(r.left, r.top, r.right, rect.bottom - half);
      }
      if ((o.right - rect.left).abs() < eps && overlapsY(o)) {
        r = Rect.fromLTRB(rect.left + half, r.top, r.right, r.bottom);
      }
      if ((o.left - rect.right).abs() < eps && overlapsY(o)) {
        r = Rect.fromLTRB(r.left, r.top, rect.right - half, r.bottom);
      }
    }
    return r;
  }

  List<Rect> _regionRowRects(SectionTintRegion r) => _rangeRowRects(score,
      scale, r.startMeasureIndex, r.startNote, r.endMeasureIndex, r.endNote);

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
double annotationWantSpaces(
  EngravedScore score,
  double scale, {
  bool withNameRow = false,
}) {
  final space = score.staffSpaceViewBox * scale;
  if (space <= 0) return 0;
  final full = annotationStackFor(
    budgetPx: double.infinity,
    staffSpacePx: space,
    labelShare: chordLabelSizeFraction,
    typeShare: underlineTextFraction,
    withChordBar: score.harmAnchors.isNotEmpty || withNameRow,
    withFingeringRow: score.fingAnchors.isNotEmpty,
  );
  return (full.barHeight + full.channelHeight + full.gap) / space;
}

/// The room the tightest system offers for the annotation stack, in screen px:
/// from the previous system's ink down to that system's own annotation register.
///
/// Score-wide MINIMUM, deliberately, because [annotationStackFor] has to give one
/// answer for every system — see there for why uniformity matters more here than
/// letting each system use what it happens to have.
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
///
/// [withNameRow]: the note names share the chord bar's row, so turning them on
/// claims that row even on a score with no chords.
({double barHeight, double channelHeight, double gap}) annotationStackOf(
  EngravedScore score,
  double scale, {
  bool withNameRow = false,
}) => annotationStackFor(
  budgetPx: _annotationBudget(score, scale),
  staffSpacePx: score.staffSpaceViewBox * scale,
  labelShare: chordLabelSizeFraction,
  typeShare: underlineTextFraction,
  // Only the rows this score will actually draw get to claim room. Verovio
  // engraved no `<harm>` ⇒ `harmRegister` is null on every system ⇒ no bar is
  // ever painted, and the same for the channel in the tab view.
  withChordBar: score.harmAnchors.isNotEmpty || withNameRow,
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
  double width, {
  bool withNameRow = false,
}) {
  final register = score.fingRegister(line);
  if (register == null) return null;
  final h =
      annotationStackOf(score, scale, withNameRow: withNameRow).channelHeight;
  if (h <= 0) return null;
  final bottom = register * scale;
  return Rect.fromLTRB(0, bottom - h, width, bottom);
}

/// Drawn in the channel BETWEEN the notes and the chord lane: one coloured chip
/// per fingering label, every chip on a system at the same height.
///
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
    this.monochromeRules = false,
    this.withNameRow = false,
  });

  final EngravedScore score;
  final double scale;
  final List<FingeringAnnotation> annotations;

  /// The note-name row is claiming the upper row — see [annotationStackOf].
  final bool withNameRow;

  /// Unbroken spans on one string, for [StringColourStyle.underline]. Empty for
  /// the other styles, which say nothing about notes that carry no label.
  final List<StringRunRegion> stringRuns;

  final StringColourStyle style;

  /// Underline rules in grey, weighted by string
  /// ([underlineGreyWeightByString]) instead of coloured — for a greyscale
  /// print, where the string colours would come out as near-identical greys.
  final bool monochromeRules;

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
      fingeringChannelOn(score, line, scale, width, withNameRow: withNameRow);

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
      final weight = monochromeRules
          ? underlineGreyWeightByString[run.string]
          : 1.0;
      final colour = !monochromeRules
          ? ViolinStringPalette.rule(run.string)
          : weight == null
              ? const Color(0xFFBBBBBB)
              : const Color(0xFF444444);
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
        final h = channelH *
            underlineRuleFraction *
            (weight ?? underlineGreyWeightByString['E']!);
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
          children: _implied(item.a, fingeringInk),
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

  /// The unsaid suffix ([FingeringAnnotation.implied]) as a faded tail on the
  /// label, in the label's own ink so it reads on any chip fill.
  static List<InlineSpan>? _implied(FingeringAnnotation a, Color ink) =>
      a.implied == null
          ? null
          : [
              TextSpan(
                  text: a.implied,
                  style: TextStyle(color: ink.withValues(alpha: 0.4))),
            ];

  /// The type size for chips in [channel] (the WHOLE fingering channel, not
  /// the chip band): what the staff asks for, capped by what the channel can
  /// host.
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
          children: _implied(item.a, ViolinStringPalette.inkOn(fill)),
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
    this.noteNames = const [],
    this.withNameRow = false,
    this.keySignature,
  });

  final EngravedScore score;
  final double scale;
  final List<ChordRunRegion> runs;

  /// See [StaffViewVerovio.keySignatureLabel].
  final KeySignatureLabel? keySignature;

  /// Note names, drawn in this same row wherever no chord bar covers the note —
  /// a score with names and chords on both is rare, so the chord wins the space.
  final List<NoteNameLabel> noteNames;

  /// The row exists for the names even without chords — see [annotationStackOf].
  final bool withNameRow;

  /// Smallest the names may shrink to (of the full size) to clear their
  /// neighbours before repeats start being dropped instead.
  static const _nameMinShrink = 0.7;

  /// Clear space between two names, as a fraction of the font size.
  static const _nameGapFraction = 0.25;

  /// Hairline pulled off each end so two adjacent runs read as separate blocks
  /// rather than one continuous ribbon (their measure edges touch exactly).
  static const _gap = 1.0;


  @override
  void paint(Canvas canvas, Size size) {
    // Per system, the x-extents the chord bars took, so the names can stay out.
    final taken = <int, List<({double left, double right})>>{};
    for (final run in runs) {
      for (final seg in _runRowRects(run, size.width)) {
        _paintSegment(canvas, seg, run);
        (taken[seg.line] ??= []).add((left: seg.rect.left, right: seg.rect.right));
      }
    }
    if (noteNames.isNotEmpty) _paintNoteNames(canvas, size.width, taken);
    final key = keySignature;
    if (key != null) _paintKeySignature(canvas, size.width, key);
  }

  static TextPainter _nameText(String text, double size,
          {FontWeight weight = FontWeight.w600}) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            height: 1.0,
            fontWeight: weight,
            color: fingeringInk,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

  /// The key signature, named where it is written (first system only).
  ///
  /// Each accidental's letter sits over it in the fingering row — empty there,
  /// since no note is — staggered by the same steps the accidentals take on the
  /// staff, squeezed only as far as the row needs. The key's name sits above
  /// them in the name row, starting over the first accidental, so `F C G` reads
  /// straight up into `A major`: the last sharp, a half step up. It gives way
  /// (shrinks, then goes) rather than run into the first note's name.
  void _paintKeySignature(
    Canvas canvas,
    double width,
    KeySignatureLabel key,
  ) {
    final bar = _barFor(0, width);
    if (bar == null) return;
    final size = (bar.bottom - bar.top) * chordLabelSizeFraction;
    if (size <= 0) return;
    final accids = score.keyAccidsOnLine(0);
    final n = math.min(accids.length, key.letters.length);

    // Letters. Their band is the fingering row where there is one.
    final channel =
        fingeringChannelOn(score, 0, scale, width, withNameRow: withNameRow);
    Rect? lastLetter; // where the arrow to the key name starts
    if (n > 0) {
      final band = channel ?? Rect.fromLTRB(0, bar.top, width, bar.bottom);
      final ys = [for (var i = 0; i < n; i++) accids[i].center.dy * scale];
      final lo = ys.reduce(math.min);
      final span = ys.reduce(math.max) - lo;
      for (var i = 0; i < n; i++) {
        final tp = _nameText(key.letters[i], size,
            weight: i == n - 1 ? FontWeight.w800 : FontWeight.w600);
        final room = band.height - tp.height;
        final k = span <= 0 || room <= 0 ? 0.0 : math.min(1.0, room / span);
        final top = band.top + math.max(0.0, room - span * k) / 2 +
            (ys[i] - lo) * k;
        final at = Offset(accids[i].center.dx * scale - tp.width / 2, top);
        tp.paint(canvas, at);
        if (i == n - 1) lastLetter = at & tp.size;
      }
    }

    // An up arrow just past the last accidental's letter, and the key's name
    // on the row above with its tonic right over the arrow: "the last sharp,
    // then up one" (G ↑ A). Drawn rather than typed, so it reaches up to the
    // tonic from however low the last letter sits in the stagger (D major's
    // C is well below its F). In C, with no accidentals, the name sits over the
    // meter. The vocabulary staff leaves a beat of space after the meter for
    // it (PaletteXmlGenerator).
    double tonicCx; // where the tonic's centre goes, if anywhere in particular
    if (lastLetter != null) {
      tonicCx = lastLetter.right + size * 0.4;
    } else if (score.meterSigs.isNotEmpty) {
      tonicCx = double.nan;
    } else {
      return;
    }
    double leftFor(double fontSize) => tonicCx.isNaN
        ? score.meterSigs.first.left * scale
        : tonicCx - _nameText(key.tonic, fontSize).width / 2;

    var right = width;
    for (final nn in noteNames) {
      if (score.lineOfMeasure(nn.measureIndex) != 0) continue;
      final note = score.noteAt(nn.measureIndex, nn.noteIndex);
      if (note == null) continue;
      final half = _nameText(nn.name, size).width / 2;
      right = math.min(right, note.rect.center.dx * scale - half);
    }
    // A wider berth than between two names, so the key doesn't read as the
    // first note's name.
    right -= size * 0.8;
    var tp = _nameText(key.keyName, size);
    var left = leftFor(size);
    if (left + tp.width > right) {
      final fit = size * (right - left) / tp.width;
      if (fit < size * 0.6) return;
      tp = _nameText(key.keyName, fit);
      left = leftFor(fit);
    }
    final nameTop = (bar.top + bar.bottom) / 2 - tp.height / 2;
    tp.paint(canvas, Offset(left, nameTop));
    final g = lastLetter;
    if (g != null) {
      _paintUpArrow(canvas, tonicCx, g.bottom - g.height * 0.15,
          nameTop + tp.height * 1.1, size);
    }
  }

  /// A vertical arrow at [x] from [fromY] up to [toY], head at the top.
  static void _paintUpArrow(
      Canvas canvas, double x, double fromY, double toY, double size) {
    if (fromY - toY < size * 0.4) return;
    final paint = Paint()
      ..color = fingeringInk
      ..strokeWidth = math.max(1.2, size * 0.11)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final head = size * 0.28;
    canvas.drawLine(Offset(x, fromY), Offset(x, toY), paint);
    canvas.drawPath(
      Path()
        ..moveTo(x - head * 0.8, toY + head)
        ..lineTo(x, toY)
        ..lineTo(x + head * 0.8, toY + head),
      paint,
    );
  }

  /// One name per note, centred over its notehead in the bar's row.
  ///
  /// Every note is named (that's the learning aim), so crowding is dealt with by
  /// shrinking the type on that system — down to [_nameMinShrink] — and only
  /// past that by dropping a name that merely repeats the one before it. A tie
  /// continuation is never named: it is the same note still sounding.
  void _paintNoteNames(
    Canvas canvas,
    double width,
    Map<int, List<({double left, double right})>> taken,
  ) {
    final byLine = <int, List<({double cx, String name})>>{};
    for (final n in noteNames) {
      if (n.held) continue;
      final line = score.lineOfMeasure(n.measureIndex);
      if (line < 0) continue;
      final note = score.noteAt(n.measureIndex, n.noteIndex);
      if (note == null) continue;
      final cx = note.rect.center.dx * scale;
      final blocked = taken[line]?.any((r) => cx >= r.left && cx <= r.right);
      if (blocked ?? false) continue;
      (byLine[line] ??= []).add((cx: cx, name: n.name));
    }

    for (final entry in byLine.entries) {
      final bar = _barFor(entry.key, width);
      if (bar == null) continue;
      final items = entry.value..sort((p, q) => p.cx.compareTo(q.cx));
      final full = (bar.bottom - bar.top) * chordLabelSizeFraction;
      if (full <= 0) continue;

      TextPainter layout(String text, double size) => _nameText(text, size);

      // The tightest neighbour pair decides this system's size.
      var shrink = 1.0;
      for (var i = 1; i < items.length; i++) {
        final pitch = items[i].cx - items[i - 1].cx;
        final need = (layout(items[i - 1].name, full).width +
                    layout(items[i].name, full).width) /
                2 +
            full * _nameGapFraction;
        if (need > 0 && pitch < need * shrink) shrink = pitch / need;
      }
      shrink = shrink.clamp(_nameMinShrink, 1.0);
      final fontSize = full * shrink;
      final gap = fontSize * _nameGapFraction;

      var lastRight = double.negativeInfinity;
      String? lastName;
      for (final it in items) {
        final tp = layout(it.name, fontSize);
        final left = it.cx - tp.width / 2;
        // Still colliding at the floor size: a repeat can go, a new name can't.
        if (left < lastRight + gap && it.name == lastName) continue;
        final top = (bar.top + bar.bottom) / 2 - tp.height / 2;
        tp.paint(canvas, Offset(left, top));
        lastRight = left + tp.width;
        lastName = it.name;
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
    final stack = annotationStackOf(score, scale, withNameRow: withNameRow);
    if (stack.barHeight <= 0) return null;
    // The bar sits directly on the fingering row where there is one, so the two
    // read as a stack rather than as two independently placed things; otherwise
    // it hangs off its own register.
    final channel =
        fingeringChannelOn(score, line, scale, width, withNameRow: withNameRow);
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
          line: e.line,
        ),
      );
    }
    return out;
  }

  @override
  bool shouldRepaint(_ChordLanePainter old) =>
      old.score != score ||
      old.scale != scale ||
      old.runs != runs ||
      old.noteNames != noteNames ||
      old.withNameRow != withNameRow ||
      old.keySignature != keySignature;
}

/// The top of the drawn annotation rows on system [line], in screen px: the
/// chord/name bar where the score has that row, else the fingering channel.
/// Null when the system carries neither — nothing drawn to clear.
///
/// The chord bar's placement mirrors [_ChordLanePainter._barFor]; the bar row
/// is claimed on every system once the score has one, so this clears it even
/// on a system whose chords happen to carry over from the one before.
double? annotationTopOn(
  EngravedScore score,
  int line,
  double scale,
  double width, {
  bool withNameRow = false,
}) {
  final stack = annotationStackOf(score, scale, withNameRow: withNameRow);
  final channel =
      fingeringChannelOn(score, line, scale, width, withNameRow: withNameRow);
  if (stack.barHeight > 0) {
    final register = score.chordRegister(line);
    final double? barBottom = channel != null
        ? channel.top - stack.gap
        : register == null
            ? null
            : register * scale - stack.gap;
    if (barBottom != null) return barBottom - stack.barHeight;
  }
  return channel?.top;
}

/// First/second-ending brackets, redrawn above the annotation rows.
///
/// Verovio places a volta over its own fingerings, which follow the notes;
/// the app flattens them into one row per system at the highest of them, so
/// in an ending over low notes the row ran straight through Verovio's
/// bracket. The engraver cuts Verovio's ink ([VerovioEngraver.stripEndings])
/// and keeps its geometry ([EngravedScore.endings]); this draws the same
/// bracket — same width, hook height, label and right hook — lifted, when it
/// has to be, to sit a gap above the rows. Where no row is drawn it stays
/// exactly where Verovio put it.
class _EndingPainter extends CustomPainter {
  _EndingPainter({
    required this.score,
    required this.scale,
    this.withNameRow = false,
  });

  final EngravedScore score;
  final double scale;
  final bool withNameRow;

  @override
  void paint(Canvas canvas, Size size) {
    if (score.endings.isEmpty) return;
    final space = score.staffSpaceViewBox * scale;
    final gap = space * 0.4;
    final stroke = Paint()
      ..color = Colors.black
      ..strokeWidth = math.max(1.0, space * 0.1)
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    for (final e in score.endings) {
      final r = Rect.fromLTRB(e.rect.left * scale, e.rect.top * scale,
          e.rect.right * scale, e.rect.bottom * scale);
      final rowTop = annotationTopOn(score, e.line, scale, size.width,
          withNameRow: withNameRow);
      final lift =
          rowTop == null ? 0.0 : math.max(0.0, r.bottom - (rowTop - gap));
      final box = r.translate(0, -lift);
      final path = Path()
        ..moveTo(box.left, box.bottom)
        ..lineTo(box.left, box.top)
        ..lineTo(box.right, box.top);
      if (e.closedRight) path.lineTo(box.right, box.bottom);
      canvas.drawPath(path, stroke);
      if (e.label.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: e.label,
          style: TextStyle(
            color: Colors.black,
            fontSize: box.height * 0.95,
            fontWeight: FontWeight.w700,
            fontFamily: 'Times New Roman',
            fontFamilyFallback: const ['serif'],
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      tp.paint(
          canvas,
          Offset(box.left + space * 0.35,
              box.bottom - tp.height + space * 0.05));
    }
  }

  @override
  bool shouldRepaint(_EndingPainter old) =>
      old.score != score ||
      old.scale != scale ||
      old.withNameRow != withNameRow;
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
  final int line; // the system it is drawn on
  const _LaneSegment({
    required this.rect,
    required this.isFirst,
    required this.isLast,
    this.line = -1,
  });
}

/// The engraved measures whose numbers label [sel]: its first, and its last
/// when that is a different bar — `(index, number)`, engraved index and the
/// model number it shows. Empty when the selection isn't engraved.
///
/// The last is the last slice that gets any highlight, by the same rule as
/// [_rangeRowRects]: an exclusive end on note 0 stops at the slice before.
/// Two slices of one split bar are one bar, so they get one label.
List<({int index, int number})> selectionLabelMeasures(
    EngravedMeasureMap map, MeasureSelection sel) {
  final r = map.range(
      sel.startMeasure, sel.startNote, sel.endMeasure, sel.endNote,
      startPerf: sel.startPerf);
  if (r == null) return const [];
  final lastIdx = r.endNote == -1
      ? r.endMeasureIndex
      : (r.endNote > 0 ? r.endMeasureIndex : r.endMeasureIndex - 1);
  if (lastIdx < r.startMeasureIndex) return const [];
  final first = (index: r.startMeasureIndex,
      number: map.numberAt(r.startMeasureIndex));
  final lastNumber = map.numberAt(lastIdx);
  if (lastNumber == first.number) return [first];
  // The label sits at the bar's left, so on a split last bar it goes on the
  // bar's first slice inside the range.
  var at = lastIdx;
  while (at > r.startMeasureIndex && map.numberAt(at - 1) == lastNumber) {
    at--;
  }
  return [first, (index: at, number: lastNumber)];
}

/// Where a measure-number label goes: the top-left corner to paint it at, so
/// that its alphabetic [baseline] (distance from the text's top) rests just
/// above the staff's top line at [staffTop], and its left sits just inside
/// the barline at [barLeft]. Screen px; [space] is one staff space.
///
/// Tight to the line deliberately: the fingering row sits on the topmost
/// fingering baseline Verovio chose, never lower than ~0.6 spaces above the
/// staff, so the band right on the line is the one place over the staff
/// nothing else claims.
///
/// A system's FIRST bar opens with its key signature (and on the first system
/// perhaps a clef and time signature), whose top sharp stands on the top line
/// right where the label would go — measured on Lightly Row, the label sat on
/// the F♯. So for that bar pass [firstNoteLeft] and the label's [textWidth]:
/// it is pushed right into the gap between the preamble and the first note,
/// ending [measureNumberNoteGap] spaces before the note. Never left of where
/// it would otherwise go.
Offset measureNumberLabelOrigin({
  required double barLeft,
  required double staffTop,
  required double space,
  required double baseline,
  double? firstNoteLeft,
  double textWidth = 0,
}) {
  var x = barLeft + space * measureNumberInset;
  if (firstNoteLeft != null) {
    x = math.max(x, firstNoteLeft - space * measureNumberNoteGap - textWidth);
  }
  return Offset(x, staffTop - space * measureNumberLift - baseline);
}

/// The touch target round each selection end handle, logical px: Apple's
/// 44 pt minimum.
const double selectionHandleTarget = 44;

/// A corner mark's arm length and stroke, logical px.
const double selectionCornerArm = 12;
const double selectionCornerStroke = 2;

/// How far a corner mark sits inside the shaded band, logical px: off the
/// band's edge, so its arms don't lie on the barline.
const double selectionCornerInset = 2.5;

/// Where a selection's bar number may start, from its bar's left edge,
/// logical px: past the top-left corner mark (inset, stroke, a gap).
const double selectionLabelCornerClearance =
    selectionCornerInset + selectionCornerStroke + 2.5;

/// How long the end handles stay after the selection last changed or a
/// handle was last used.
const Duration selectionHandleLinger = Duration(seconds: 3);

/// The engraved measure index at [p] (viewBox coordinates), or null on an
/// empty page.
///
/// By line band, not by ink box: a measure's box is its ink, so a tap in the
/// gap between two systems, or above a bar's short notes, used to hit
/// nothing. The point picks the system whose tiled band ([lineBands])
/// holds it — the first or last above or below the page — then the bar on
/// that line whose span holds x, or the nearest one past a line's end.
int? measureIndexAtPoint(EngravedScore score, Offset p) {
  final lines = score.lineBands;
  if (score.measures.isEmpty) return null;
  int line;
  if (lines.isEmpty) {
    line = -1;
  } else if (p.dy < lines.first.top) {
    line = 0;
  } else {
    line = lines.length - 1;
    for (var l = 0; l < lines.length; l++) {
      if (p.dy < lines[l].bottom) {
        line = l;
        break;
      }
    }
  }
  int? best;
  var bestDist = double.infinity;
  for (final m in score.measures) {
    if (line >= 0 && score.lineOfMeasure(m.index) != line) continue;
    if (line < 0 && !m.rect.contains(p)) continue;
    final dx = p.dx < m.rect.left
        ? m.rect.left - p.dx
        : p.dx > m.rect.right
            ? p.dx - m.rect.right
            : 0.0;
    if (dx < bestDist) {
      bestDist = dx;
      best = m.index;
      if (dx == 0) break;
    }
  }
  return best;
}

/// Gap between a system-first label and the first note, in staff spaces.
const double measureNumberNoteGap = 0.2;

/// Gap between the barline and the label, in staff spaces — clears the
/// barline's own stroke (a thin barline is ~0.15 spaces).
const double measureNumberInset = 0.3;

/// Gap between the staff's top line and the label's baseline, in staff
/// spaces — the line's half-stroke plus a hair, so the digits never touch it.
const double measureNumberLift = 0.2;

/// Label size, in staff spaces. Lining digits stand ~0.7 em, so this inks
/// about 0.65 spaces tall.
const double measureNumberFontSpaces = 0.95;

/// The measure number of a selection's first and last bar, small, on the
/// staff's top line at each bar's left. See [selectionLabelMeasures] for
/// which bars, [measureNumberLabelOrigin] for where.
class _MeasureNumberPainter extends CustomPainter {
  _MeasureNumberPainter({
    required this.score,
    required this.scale,
    required this.measureMap,
    required this.selection,
    required this.color,
  });

  final EngravedScore score;
  final double scale;
  final EngravedMeasureMap measureMap;
  final MeasureSelection selection;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final space = score.staffSpaceViewBox * scale;
    if (space <= 0) return;
    final fontSize = (space * measureNumberFontSpaces).clamp(8.0, 18.0);
    for (final m in selectionLabelMeasures(measureMap, selection)) {
      final staff = score.staffLineAt(m.index);
      if (staff == null) continue;
      TextPainter label(Paint? stroke) => TextPainter(
            text: TextSpan(
              text: '${m.number}',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                height: 1.0,
                foreground: stroke,
                color: stroke == null ? color : null,
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
      // A white halo first, so the digits read over a ledger line, a stem or
      // a chip's edge.
      final halo = label(Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.0, fontSize * 0.22)
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white);
      final ink = label(null);
      // A system's first bar: clear its key signature (see the origin).
      final opensSystem = m.index == 0 ||
          score.lineOfMeasure(m.index - 1) != score.lineOfMeasure(m.index);
      final firstNote = opensSystem ? score.noteAt(m.index, 0) : null;
      var at = measureNumberLabelOrigin(
        barLeft: staff.left * scale,
        staffTop: staff.top * scale,
        space: space,
        baseline: ink.computeDistanceToActualBaseline(TextBaseline.alphabetic),
        firstNoteLeft: firstNote == null ? null : firstNote.rect.left * scale,
        textWidth: ink.width,
      );
      // Always clear of the selection's corner marks (whether or not they
      // are showing, so the number doesn't jump when they fade): the
      // top-left mark's arm runs down the bar's left edge, where the label
      // would otherwise start.
      final clear = staff.left * scale + selectionLabelCornerClearance;
      if (at.dx < clear) at = Offset(clear, at.dy);
      halo.paint(canvas, at);
      ink.paint(canvas, at);
    }
  }

  @override
  bool shouldRepaint(_MeasureNumberPainter old) =>
      old.score != score ||
      old.scale != scale ||
      old.measureMap != measureMap ||
      old.selection != selection ||
      old.color != color;
}

/// Drawn OVER the notation: selection range, flagged markers, current-note
/// highlight, and the playback cursor. Repaints when [highlight] ticks.
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required Listenable repaint,
    required this.score,
    required this.scale,
    required this.measureMap,
    required this.selection,
    required this.flaggedMeasures,
    required this.highlight,
    required this.primary,
    required this.flagColor,
  }) : super(repaint: repaint);

  final EngravedScore score;
  final double scale;
  final EngravedMeasureMap measureMap;
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

  @override
  void paint(Canvas canvas, Size size) {
    // Selection range fill, through the same note-edged geometry as the
    // section wash: a selected section covers exactly its tint, mid-bar
    // starts and ends included, on the same tiled per-line bands.
    final sel = selection;
    if (sel != null) {
      final r = measureMap.range(
          sel.startMeasure, sel.startNote, sel.endMeasure, sel.endNote,
          startPerf: sel.startPerf);
      if (r != null) {
        final fill = Paint()..color = primary.withValues(alpha: 0.16);
        // A pass that skips a bar (a first ending, on the second time
        // through) is drawn in pieces around it.
        var from = r.startMeasureIndex, fromNote = r.startNote;
        for (var i = r.startMeasureIndex; i <= r.endMeasureIndex + 1; i++) {
          final end = i > r.endMeasureIndex;
          if (!end && !sel.skipped.contains(measureMap.numberAt(i))) continue;
          if (i > from) {
            final last = end ? r.endMeasureIndex : i - 1;
            for (final rect in _rangeRowRects(score, scale, from, fromNote,
                last, end ? r.endNote : -1)) {
              canvas.drawRect(rect, fill);
            }
          }
          from = i + 1;
          fromNote = 0;
        }
      }
    }

    // Flagged-measure markers: a small warning triangle at the measure's top-left.
    for (final number in flaggedMeasures) {
      final i = measureMap.firstIndexOf(number);
      final m = score.measureAt(i);
      if (m == null) continue;
      _drawFlag(canvas, _scaled(m.rect), (_bandPx(i) * 0.13).clamp(7.0, 26.0));
    }

    // Current-note highlight + playback cursor.
    final ev = highlight.value;
    if (ev != null) {
      final at = measureMap.locatePlayed(
          ev.measureNumber, ev.noteIndex, ev.performanceIndex);
      final mi = at?.index ?? -1;
      final anchor = at == null ? null : score.noteAt(at.index, at.note);
      final restBeat = ev.restBeat;
      final beatRect = restBeat == null || at == null
          ? null
          : _restBeatRect(mi, at.note, ev.restSlice, ev.restSlices);
      if (beatRect != null) {
        _drawRestBeat(canvas, beatRect, restBeat! + 1, _bandPx(mi));
      } else if (anchor != null) {
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
    // The tiled band itself, not [EngravedScore.bandForMeasure]'s, whose
    // last line reaches down over its lyrics: a decoration shouldn't grow there.
    final l = score.lineOfMeasure(measureIndex);
    final band =
        l < 0 || l >= score.lineBands.length ? null : score.lineBands[l];
    if (band == null) return 48 * scale;
    return (band.bottom - band.top) * scale;
  }

  /// Beat [beat] of [beats] of the long rest at [note] in engraved measure
  /// [mi]: an equal slice of the room the rest has — from the previous note
  /// (or the bar's start, after any clef/key/time it opens with) to the next
  /// note (or the bar's end). Null when the measure isn't on screen.
  Rect? _restBeatRect(int mi, int note, int beat, int beats) {
    final m = score.measureAt(mi);
    if (m == null || beats < 1) return null;
    var left = m.rect.left;
    for (final r in [...score.meterSigs, ...score.keyAccids]) {
      final c = r.center;
      if (c.dx > m.rect.left && c.dx < m.rect.right &&
          c.dy > m.rect.top && c.dy < m.rect.bottom && r.right > left) {
        left = r.right;
      }
    }
    final prev = note > 0 ? score.noteAt(mi, note - 1) : null;
    if (prev != null && prev.rect.right > left) left = prev.rect.right;
    var right = m.rect.right;
    final next = score.noteAt(mi, note + 1);
    if (next != null && next.rect.left > left) right = next.rect.left;
    final w = (right - left) / beats;
    if (w <= 0) return null;
    return _scaled(Rect.fromLTRB(
        left + w * beat, m.rect.top, left + w * (beat + 1), m.rect.bottom));
  }

  /// The rest-beat highlight: the slice, tinted and outlined like a note's,
  /// with the beat's number above it to count by.
  void _drawRestBeat(Canvas canvas, Rect slice, int number, double band) {
    final pad = (band * 0.035).clamp(2.0, 9.0);
    final r = slice.deflate(pad / 2);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(pad));
    canvas.drawRRect(rr, Paint()..color = primary.withValues(alpha: 0.18));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (pad * 0.5).clamp(1.0, 3.0)
        ..color = primary.withValues(alpha: 0.7),
    );
    final label = TextPainter(
      text: TextSpan(
        text: '$number',
        style: TextStyle(
          color: primary,
          fontSize: (band * 0.22).clamp(11.0, 28.0),
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(
        canvas,
        Offset(r.center.dx - label.width / 2,
            r.center.dy - label.height / 2));
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
      old.measureMap != measureMap ||
      old.primary != primary ||
      // flagColor too: a theme change that moves only the error colour would
      // otherwise leave every flag painted in the old one.
      old.flagColor != flagColor;
}


/// One corner mark of the selection: an L drawn at [corner] (in this
/// box), its arms running right or left ([pointsRight]) and down or up
/// ([pointsDown]) along the selection's edges, inside a full-size touch
/// target. A tap is [onTap]; a drag reports where the finger is
/// ([onDragTo], global) as it moves.
///
/// It claims the pointer the moment it lands ([_EagerPointerRecognizer]):
/// a drag that starts on a corner is the corner's, in any direction, not
/// the scroll view's. Safe because the marks are small and only there
/// briefly.
class _CornerHandle extends StatefulWidget {
  const _CornerHandle({
    super.key,
    required this.corner,
    required this.pointsRight,
    required this.pointsDown,
    required this.color,
    required this.label,
    required this.onTap,
    required this.onDragTo,
  });

  final Offset corner;
  final bool pointsRight;
  final bool pointsDown;
  final Color color;
  final String label;

  /// Tapped, with where the finger came down (global).
  final ValueChanged<Offset> onTap;
  final ValueChanged<Offset> onDragTo;

  @override
  State<_CornerHandle> createState() => _CornerHandleState();
}

class _CornerHandleState extends State<_CornerHandle> {
  Offset? _down;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) widget.onTap(box.localToGlobal(box.size.center(Offset.zero)));
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          _EagerPointerRecognizer:
              GestureRecognizerFactoryWithHandlers<_EagerPointerRecognizer>(
            _EagerPointerRecognizer.new,
            (r) => r
              ..onDown = (p) {
                _down = p;
                _dragging = false;
              }
              ..onMove = (p) {
                final down = _down;
                if (down == null) return;
                if (!_dragging && (p - down).distance > kTouchSlop) {
                  _dragging = true;
                }
                if (_dragging) widget.onDragTo(p);
              }
              ..onUp = () {
                final down = _down;
                if (down != null && !_dragging) widget.onTap(down);
                _down = null;
                _dragging = false;
              }
              ..onCancel = () {
                _down = null;
                _dragging = false;
              },
          ),
        },
        child: CustomPaint(
          painter: _CornerPainter(
            corner: widget.corner,
            dx: widget.pointsRight ? 1 : -1,
            dy: widget.pointsDown ? 1 : -1,
            color: widget.color,
          ),
        ),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  _CornerPainter({
    required this.corner,
    required this.dx,
    required this.dy,
    required this.color,
  });

  final Offset corner;
  final double dx, dy;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const arm = selectionCornerArm;
    canvas.drawPath(
      Path()
        ..moveTo(corner.dx + dx * arm, corner.dy)
        ..lineTo(corner.dx, corner.dy)
        ..lineTo(corner.dx, corner.dy + dy * arm),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = selectionCornerStroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CornerPainter old) =>
      old.corner != corner ||
      old.dx != dx ||
      old.dy != dy ||
      old.color != color;
}

/// Wins the gesture arena on pointer down, then reports the pointer's
/// global position until it lifts.
class _EagerPointerRecognizer extends OneSequenceGestureRecognizer {
  _EagerPointerRecognizer({super.debugOwner});

  ValueChanged<Offset>? onDown;
  ValueChanged<Offset>? onMove;
  VoidCallback? onUp;
  VoidCallback? onCancel;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
    onDown?.call(event.position);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      onMove?.call(event.position);
    } else if (event is PointerUpEvent) {
      onUp?.call();
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      onCancel?.call();
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    onCancel?.call();
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'selection edge pin';
}

import 'dart:convert';
import 'dart:ui' show Rect, Size, Offset;

import 'package:flutter/foundation.dart';
import 'package:verovio_flutter/verovio_flutter.dart';

import 'staff_zoom.dart'
    show
        lineContentOf,
        measuresPerLineOf,
        staffHeightUnits,
        staffScaleProbe,
        systemLinesOf,
        verovioPageMarginTopDefault;

/// Native staff engraving via the Verovio toolkit (FFI worker isolate).
///
/// Verovio does layout/coordinates; a Flutter renderer (jovial_svg) draws the
/// returned SVG and native overlays draw selection/highlight/cursor on top.
/// The migration plan itself is gone; the surviving record of what the spike
/// established is `docs/explore.md` §10.
///
/// Phase 0 proved jovial_svg renders Verovio's SVG faithfully and that
/// `hitMap` bboxes are in the OUTER page viewBox space (shared with the render),
/// so no hand-written Canvas painter is needed.
///
/// One long-lived [VerovioAsyncService] is shared (the toolkit is single-score
/// and not thread-safe; the worker isolate serializes calls). [engrave] is
/// additionally serialized so two concurrent callers can't interleave a
/// `loadData`/`renderPageWithHitMap` pair against different scores.
class VerovioEngraver {
  VerovioEngraver._();
  static final VerovioEngraver instance = VerovioEngraver._();

  /// Verbose correlation/diagnostics logging (debug only).
  static bool debugLogging = false;

  VerovioAsyncService? _svc;
  Future<VerovioAsyncService>? _spawning;

  /// The interactive default (`note`, `rest`, `measure`) plus the meter
  /// signature, which is an ANCHOR rather than a hit target: the count-in
  /// display is specified as sitting just above the time signature, and only the
  /// hit map knows where the engraver put it. Cheap — one more element per meter
  /// change, and the parse is already walking the whole page.
  ///
  /// Plus `fing` and `harm` — Verovio's own engraved fingerings and chord
  /// symbols. Those are captured for their ANCHOR only; see [AnnotationAnchor]
  /// for why their reported extent is useless and why that doesn't matter.
  static const _hitMapConfig = ParseConfig(
    captureClasses: {'note', 'rest', 'measure', 'meterSig', 'fing', 'harm'},
  );

  // Small LRU-ish cache keyed by (xmlHash, widthBucket, scale). Reflow on
  // rotation/resize and the live measure editor re-engrave hit the cache when
  // the inputs are unchanged. Sized to hold a handful of zoom levels alongside
  // the width buckets and the tab/non-tab variants.
  final _cache = <String, EngravedScore>{};
  static const _maxCache = 16;

  // Serializes full engrave round-trips (the worker serializes individual
  // calls, but a score swap spans several calls that must stay atomic).
  Future<void> _tail = Future<void>.value();

  Future<VerovioAsyncService> _ensureService() {
    final svc = _svc;
    if (svc != null) return Future.value(svc);
    return _spawning ??= () async {
      final resourcePath =
          await VerovioResourceManager.ensureVerovioAssetsReady();
      final svc = await VerovioAsyncService.spawn(resourcePath: resourcePath);
      _svc = svc;
      _spawning = null;
      return svc;
    }();
  }

  /// Width bucket so sub-pixel resize jitter doesn't re-engrave. ~48px steps.
  static int _bucketOf(double widthPx) => (widthPx / 48).round();

  static String _keyFor(
    String xml,
    double widthPx,
    double scale,
    String variant,
  ) =>
      '${xml.hashCode}|${_bucketOf(widthPx)}|${scale.toStringAsFixed(1)}|$variant';

  /// Engrave [musicXml] targeting [widthPx] logical pixels of render width.
  ///
  /// Returns an [EngravedScore]: the jovial-ready SVG, the page viewBox, and
  /// index-based geometric anchors for measures and notes. The score is
  /// domain-free — callers map a measure's document [index] to their model
  /// measure number (the same index↔number contract the OSMD bridge used).
  ///
  /// Tab-view options (see the tab-view plan / [TabScoreGenerator]):
  /// - [tabFingerLabels]: when non-null, each rendered tab fret `<text>` (in
  ///   document order) is replaced with the corresponding label — the violin
  ///   fingering. Null leaves Verovio's native fret numbers (fret mode).
  /// - [tabMode]: the score has a second (tab) staff; exclude its notes/rests
  ///   from the note anchors so the highlight/cursor stay on the melody staff.
  /// - [stripRepeatClefs]: keep the single-staff practice view's "clef/keySig on
  ///   the first system only" trim. Set false for the tab view so the small
  ///   "T-A-B" clef repeats per system (standard tab engraving).
  ///
  /// Zoom options (see `staff_zoom.dart`):
  /// - [scale]: Verovio's percentage scale. Because [widthPx] pins the page
  ///   width, this simultaneously sets glyph size and how many measures fit per
  ///   system. [staffScaleProbe] is the un-zoomed baseline.
  /// - [pageHeightUnits]: must exceed the engraved content height — only page 1
  ///   is ever rendered, so anything below the page bottom is silently dropped.
  ///   `adjustPageHeight` crops the slack, so over-provisioning is free. Compute
  ///   with `pageHeightUnitsFor`.
  /// - [mnumInterval]: Verovio's bar-number interval. **0 (the default) draws
  ///   none**, which is what every view here wants: an engraved bar number sits
  ///   in the same strip of whitespace the annotation lanes are drawn in, so it
  ///   lands on top of the fingering row. The reader's position cues are the
  ///   section minimap and the A/B part markers, neither of which collides with
  ///   anything. Kept as a parameter because it is a legitimate Verovio option,
  ///   not because anything passes it.
  /// - [spacingSystem]: vertical gap between systems in MEI units, passed to
  ///   Verovio verbatim. Compose it with `verovioSpacingSystemForEngrave`: the
  ///   "Staff spacing" preference, plus the annotation-room reserve when the
  ///   score carries annotations to reserve for.
  /// - [pageMarginTop]: the page's top margin in MEI units — the room system 0's
  ///   annotation rows are drawn in, there being no system above it to borrow
  ///   from. Compose with `verovioPageMarginTopForEngrave`.
  /// - [breaks]: Verovio's line-breaking mode. `'auto'` (the default) lets
  ///   Verovio choose its own break points, which is what every zoom level
  ///   solves a `scale` to approximately steer (see `staff_zoom.dart`).
  ///   `'encoded'` instead honors explicit `<print new-system="yes"/>` markers
  ///   already present in [musicXml] (see `insertSystemBreaksEvery`) — the
  ///   mechanism behind a guaranteed-exact "lock to N measures per line".
  Future<EngravedScore> engrave(
    String musicXml, {
    required double widthPx,
    double scale = staffScaleProbe,
    int pageHeightUnits = 60000,
    int mnumInterval = 0,
    int spacingSystem = 12,
    int pageMarginTop = verovioPageMarginTopDefault,
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
    String breaks = 'auto',
  }) {
    // Both lane flags go in the key, not just their count: a chords-only and a
    // fingering-only score engrave identically, but the bands are read back off
    // the returned object, so they must not share an entry.
    final variant =
        '${stripRepeatClefs ? 1 : 0}${tabMode ? 1 : 0}'
        '|$pageHeightUnits|$mnumInterval|$spacingSystem|$pageMarginTop|$breaks'
        '|'
        '${tabFingerLabels == null ? '-' : tabFingerLabels.join(',').hashCode}';
    final key = _keyFor(musicXml, widthPx, scale, variant);
    final cached = _cache[key];
    if (cached != null) {
      // Touch for LRU.
      _cache.remove(key);
      _cache[key] = cached;
      return Future.value(cached);
    }
    // Chain onto the serialization tail.
    final result = _tail.then((_) async {
      final again = _cache[key];
      if (again != null) return again;
      final score = await _engraveNow(
        musicXml,
        widthPx: widthPx,
        scale: scale,
        pageHeightUnits: pageHeightUnits,
        mnumInterval: mnumInterval,
        spacingSystem: spacingSystem,
        pageMarginTop: pageMarginTop,
        tabFingerLabels: tabFingerLabels,
        tabMode: tabMode,
        stripRepeatClefs: stripRepeatClefs,
        breaks: breaks,
      );
      _cache[key] = score;
      if (_cache.length > _maxCache) {
        _cache.remove(_cache.keys.first);
      }
      return score;
    });
    // Keep the tail alive even if this engrave throws.
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<EngravedScore> _engraveNow(
    String musicXml, {
    required double widthPx,
    required double scale,
    required int pageHeightUnits,
    required int mnumInterval,
    required int spacingSystem,
    required int pageMarginTop,
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
    String breaks = 'auto',
  }) async {
    final svc = await _ensureService();
    final sw = Stopwatch()..start();

    // pageWidth is in MEI units; rendered viewBox px ≈ pageWidth * scale / 100.
    final pageWidthUnits = (widthPx * 100 / scale).round();
    final options = <String, Object>{
      'scale': scale.round(),
      'pageWidth': pageWidthUnits,
      // Force everything onto a single page: without an explicit pageHeight
      // Verovio uses its ~A4 default, so once stacked systems exceed it the
      // overflow spills to page 2+ — which we never render (we only ask for
      // page 1). That's invisible in landscape (wide → few systems → fits) but
      // clips the bottom of the score in portrait (narrow → many systems), and
      // zooming in makes it far easier to hit. A generous page guarantees one
      // page; adjustPageHeight then crops the slack. See `pageHeightUnitsFor`.
      'pageHeight': pageHeightUnits,
      'adjustPageHeight': true,
      'breaks': breaks,
      'footer': 'none',
      'header': 'none',
      'mnumInterval': mnumInterval,
      // Vertical gap between systems — the "Staff spacing" preference plus the
      // caller's annotation-room reserve. One unit is half a staff space; see
      // `spacesPerSpacingSystemUnit`.
      'spacingSystem': spacingSystem,
      // System 0's annotation rows sit in the page's top margin, which has no
      // gap above it to borrow from, so the reserve has to be asked for here
      // separately — and at 1/18 of a space per unit, in very different money.
      'pageMarginTop': pageMarginTop,
      'svgViewBox': true, // root viewBox so the renderer can scale
      // Verovio's OWN geometry, for the one measurement we cannot compute:
      // where a system's ink really ends. See [systemInkBoxes]. The groups are
      // cut back out before the SVG is rendered ([stripBoundingBoxes]), so this
      // costs a bigger string through the worker and nothing else — it does not
      // move the layout (verified: identical viewBox and system count with it
      // on and off).
      'svgBoundingBoxes': true,
    };
    await svc.setOptionsJson(jsonEncode(options));
    await svc.loadData(stripPartLabels(musicXml));

    final res = await svc.renderPageWithHitMap(1, config: _hitMapConfig);
    final hitMap = res.hitMap;

    // Optional timemap → qstamp per sounding note (cursor fallback).
    final qstampById = <String, double>{};
    try {
      final tm = jsonDecode(await svc.renderToTimemap()) as List;
      for (final entry in tm) {
        if (entry is! Map) continue;
        final q = (entry['qstamp'] as num?)?.toDouble();
        final on = entry['on'];
        if (q == null || on is! List) continue;
        for (final id in on) {
          if (id is String) qstampById[id] = q;
        }
      }
    } catch (e) {
      if (debugLogging) debugPrint('[engraver] timemap skipped: $e');
    }

    final score = _buildScore(
      svg: res.svg,
      hitMap: hitMap,
      qstampById: qstampById,
      pageWidthUnits: pageWidthUnits,
      renderMs: sw.elapsedMilliseconds,
      tabFingerLabels: tabFingerLabels,
      tabMode: tabMode,
      stripRepeatClefs: stripRepeatClefs,
    );
    if (debugLogging) {
      debugPrint(
        '[engraver] engraved viewBox=${score.viewBox.width.toInt()}'
        '×${score.viewBox.height.toInt()} measures=${score.measures.length} '
        'notes=${score.notes.length} scale=${scale.toStringAsFixed(1)} '
        'pageW=$pageWidthUnits lines=${score.lineCount} '
        'mpl=${measuresPerLineOf(score.measureLine)} ${score.renderMs}ms',
      );
      // Where Verovio put its own annotations, per system — the register the
      // app draws on. `fing`/`harm` counts of 0 in the annotated view mean the
      // injection didn't land, which is the first thing to check if the row
      // goes missing. Offsets are in staff spaces above the system's ink top,
      // which is the scale-invariant way to read them.
      final c = score.lineContent;
      final space = score.staffSpaceViewBox;
      String reg(double? y, int l) => (y == null || space <= 0 || l >= c.length)
          ? '-'
          : ((c[l].top - y) / space).toStringAsFixed(2);
      // Per system, the two registers the app draws on and the room above them.
      // This is the line that diagnoses a bad annotation layout: `harm`/`fing`
      // absent means the injection didn't land on that system, and roomAboveFing
      // is the budget `annotationStackFor` has to divide between the chord bar
      // and the fingering row. A row that looks present at the top and bottom of
      // a page and missing in the middle is this number varying.
      //
      // With the reserve applied this should read at or just above what the
      // stack wants — 6.03 spaces for a score carrying both rows, 3.16 for one
      // carrying fingerings alone. Materially under that means the reserve did
      // not reach Verovio: check `scoreReservesAnnotationRoom` said yes for this
      // xml, that `annotationReserveFor` was given the probe's rooms and not the
      // real engrave's, and that pageMarginTop came out at or under 500, past
      // which Verovio silently ignores it. Materially OVER it means we are
      // buying whitespace, which is the bug this all exists to remove.
      for (var l = 0; l < score.lineCount; l++) {
        final h = score.harmRegister(l);
        final f = score.fingRegister(l);
        final prev = l == 0 ? 0.0 : score.lineContent[l - 1].bottom;
        debugPrint('[engraver] L$l inkTop=${c[l].top.toStringAsFixed(1)} '
            'harm=${h?.toStringAsFixed(1) ?? "-"} '
            'fing=${f?.toStringAsFixed(1) ?? "-"} '
            'prevBot=${prev.toStringAsFixed(1)} '
            'roomAboveFing=${f == null ? "-" : ((f - prev) / space).toStringAsFixed(2)}sp');
      }
      debugPrint(
        '[engraver] annot fing=${score.fingAnchors.length} '
        'harm=${score.harmAnchors.length} space=${space.toStringAsFixed(2)} '
        'fingReg0=${reg(score.fingRegister(0), 0)} '
        'harmReg0=${reg(score.harmRegister(0), 0)} '
        'top0=${c.isEmpty ? -1 : c.first.top.toStringAsFixed(1)} '
        'gap1=${c.length > 1 ? (c[1].top - c[0].bottom).toStringAsFixed(1) : '-'} '
        'sysH=${score.systemHeightViewBox.toStringAsFixed(1)}',
      );
    }
    return score;
  }

  EngravedScore _buildScore({
    required String svg,
    required PageHitMap hitMap,
    required Map<String, double> qstampById,
    required int pageWidthUnits,
    required int renderMs,
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
  }) {
    // `svgBoundingBoxes` makes Verovio emit a `<g class="note bounding-box">`
    // beside every `<g class="note">`, and the hit map types an element by its
    // FIRST class token — so every captured class would be counted twice, with
    // the phantom sitting on the real one. They all carry a `bbox-` id prefix,
    // which is the only thing distinguishing them. Filtered once, here, so no
    // consumer below has to know.
    final hits = hitMap.byType
        .where((h) => !h.id.startsWith(_bboxIdPrefix))
        .toList();

    final bboxById = <String, Rect>{for (final h in hits) h.id: h.bbox};

    // Measures in document order (byType preserves DFS / document order).
    final measureHits = hits
        .where((h) => h.type == 'measure')
        .toList();
    final measures = <MeasureAnchor>[
      for (var i = 0; i < measureHits.length; i++)
        MeasureAnchor(
          index: i,
          id: measureHits[i].id,
          rect: measureHits[i].bbox,
        ),
    ];

    // Tab view: the second staff duplicates the melody. Exclude its notes/rests
    // from the anchors so positional noteIndex (and thus the highlight/cursor,
    // which map a model note → anchor) stays on the melody staff.
    final tabIds = tabMode ? _tabStaffElementIds(svg) : const <String>{};

    // Assign each note/rest to the measure whose bbox contains its center,
    // then rank within the measure by x to get our positional noteIndex
    // (which counts rests). This is robust to qstamp/tick alignment quirks.
    final noteHits = hits
        .where(
          (h) =>
              (h.type == 'note' || h.type == 'rest') && !tabIds.contains(h.id),
        )
        .toList();
    final perMeasure = <int, List<ElementHit>>{};
    for (final h in noteHits) {
      final mi = _measureIndexFor(h.bbox, measures);
      if (mi < 0) continue;
      (perMeasure[mi] ??= <ElementHit>[]).add(h);
    }
    final notes = <NoteAnchor>[];
    for (final entry in perMeasure.entries) {
      final list = entry.value
        ..sort((a, b) => a.bbox.left.compareTo(b.bbox.left));
      for (var ni = 0; ni < list.length; ni++) {
        final h = list[ni];
        final q = qstampById[h.id];
        notes.add(
          NoteAnchor(
            id: h.id,
            measureIndex: entry.key,
            noteIndex: ni,
            isRest: h.type == 'rest',
            rect: h.bbox,
            // beatPosition is in whole-note units (our HighlightEvent convention);
            // Verovio qstamp is in quarter-note units → divide by 4.
            beatPosition: q == null ? null : q / 4,
          ),
        );
      }
    }

    // Meter signatures in document order. Normally exactly one (Verovio engraves
    // it on the first system only unless the meter changes mid-piece), so the
    // count-in anchors to `meterSigs.first` and falls back to a measure's left
    // edge when the score has none.
    final meterSigs = <Rect>[
      for (final h in hits)
        if (h.type == 'meterSig') h.bbox,
    ];

    final measureRects = [for (final m in measures) m.rect];
    final (measureLine, lineBands) = systemLinesOf(measureRects);
    // Verovio's own per-system extent where the SVG carries it, the hit map's
    // measure union as the fallback. The two disagree by ~2 staff spaces and
    // Verovio is the one telling the truth — see [systemInkBoxes]. Guarded on
    // the counts matching, so a disagreement about how many systems there are
    // falls back rather than pairing a box with the wrong band.
    final inkBoxes = systemInkBoxes(svg);
    final lineContent = (inkBoxes != null && inkBoxes.length == lineBands.length)
        ? inkBoxes
        : lineContentOf(measureRects, measureLine);

    // Verovio's own annotations, reduced to their anchors and assigned to a
    // system by the TILED band their baseline falls in.
    //
    // Bands rather than measure containment. Both work — an engraved annotation
    // is inside its measure's bbox, on one staff or two
    // (`verovio_annotation_anchor_test.dart` pins that) — but the bands tile the
    // page with no gaps, so every baseline lands in exactly one and there is no
    // "belongs to no measure" case to decide what to do about. Anything above the
    // first band belongs to the first system, there being nothing above it.
    int lineForY(double y) {
      for (var l = 0; l < lineBands.length; l++) {
        if (y <= lineBands[l].bottom) return l;
      }
      return lineBands.isEmpty ? 0 : lineBands.length - 1;
    }

    List<AnnotationAnchor> anchorsOf(String type) => [
      for (final h in hits)
        if (h.type == type)
          (line: lineForY(h.bbox.top), x: h.bbox.left, y: h.bbox.top),
    ];
    final fingAnchors = anchorsOf('fing');
    final harmAnchors = anchorsOf('harm');

    // The measuring boxes have served their purpose (above); out they go before
    // any other surgery, so everything downstream — and everything the renderer
    // sees — is the same SVG it was before this option was turned on.
    var processedSvg = stripBoundingBoxes(svg);
    processedSvg = stripMeasureNumbers(processedSvg);
    // After the hit map: the anchors are already recorded, and the reserved
    // space stays. See [stripAnnotationGlyphs].
    processedSvg = stripAnnotationGlyphs(processedSvg);
    if (stripRepeatClefs)
      processedSvg = clefKeySigFirstSystemOnly(processedSvg);
    if (tabFingerLabels != null) {
      processedSvg = _swapTabFingerings(processedSvg, tabFingerLabels);
    }
    processedSvg = flattenForRenderer(processedSvg);

    return EngravedScore(
      viewBox: hitMap.viewBox,
      svg: processedSvg,
      bboxById: bboxById,
      measures: measures,
      notes: notes,
      meterSigs: meterSigs,
      measureLine: measureLine,
      lineBands: lineBands,
      lineContent: lineContent,
      fingAnchors: fingAnchors,
      harmAnchors: harmAnchors,
      pageWidthUnits: pageWidthUnits,
      renderMs: renderMs,
    );
  }

  /// Index of the measure whose bbox contains [box]'s center, else the nearest
  /// by horizontal center (notes can sit a hair outside the staff bbox).
  static int _measureIndexFor(Rect box, List<MeasureAnchor> measures) {
    final c = box.center;
    for (final m in measures) {
      if (m.rect.contains(c)) return m.index;
    }
    var best = -1;
    var bestDist = double.infinity;
    for (final m in measures) {
      // Same system (vertical overlap) and nearest in x.
      final vOverlap = box.top < m.rect.bottom && box.bottom > m.rect.top;
      if (!vOverlap) continue;
      final dx = (m.rect.center.dx - c.dx).abs();
      if (dx < bestDist) {
        bestDist = dx;
        best = m.index;
      }
    }
    return best;
  }

  /// Removes the instrument labels Verovio engraves at the left of each system
  /// (the full `<part-name>` on the first system, the `<part-abbreviation>` on
  /// later ones). For a single-instrument practice score these add no
  /// information and just eat horizontal space, so we blank them at the source
  /// rather than indenting around them. We empty the elements (and mark them
  /// `print-object="no"`) instead of deleting, so the part structure is
  /// untouched. `<instrument-name>` isn't engraved but is blanked for symmetry.
  static String stripPartLabels(String xml) {
    var out = xml;
    // `print-object="no"` is the canonical MusicXML way to suppress a label;
    // emptying the text also gives Verovio zero label width to indent for.
    for (final tag in const ['part-name', 'part-abbreviation']) {
      out = out.replaceAllMapped(
        RegExp('<$tag\\b[^>]*>.*?</$tag>', dotAll: true),
        (_) => '<$tag print-object="no"></$tag>',
      );
    }
    // `instrument-name` isn't engraved, but blank it too for symmetry.
    out = out.replaceAll(
      RegExp('<instrument-name\\b[^>]*>.*?</instrument-name>', dotAll: true),
      '<instrument-name></instrument-name>',
    );
    return out;
  }

  /// Keeps the clef only on the FIRST system, stripping the copies Verovio
  /// re-engraves at the start of every subsequent system. This is a
  /// deliberate departure from standard engraving (which repeats the clef per
  /// line) for this single-staff practice view. The notes keep their engraved
  /// x positions, so later systems carry a small leading indent where the
  /// removed glyphs were — hitMap coordinates are untouched, so overlays,
  /// the cursor, and taps stay aligned.
  ///
  /// The key signature is deliberately NOT included here — unlike clef/time
  /// it's left to repeat on every system, standard engraving practice, so a
  /// player can tell the key from wherever they land on the page. This is
  /// mostly a fallback for `breaks: 'auto'` (no explicit system breaks): the
  /// usual "locked measures per line" path already keeps the key signature
  /// (and hides clef/time) at the MusicXML source, see `_hidePreamble` in
  /// `system_break_injector.dart`.
  static String clefKeySigFirstSystemOnly(String svg) => _removeGroups(svg, [
    ..._repeatedGroupRanges(svg, 'clef'),
  ]);

  /// Removes Verovio's engraved bar numbers.
  ///
  /// They cannot stay: a bar number is drawn into the strip of whitespace above
  /// the staff, which is the same strip the annotation lanes are drawn in, so it
  /// lands among the fingering numbers. Nor is the `mnumInterval` option a way
  /// out — 0 does not mean "none", it means "number the first bar of each
  /// system", which just moves the collision to the left margin (where it also
  /// gets clipped by the page edge).
  ///
  /// Position is still cued, by things that cannot collide: the section minimap
  /// and the A/B part markers down the side.
  ///
  /// Both spellings are removed because the class is Verovio's MEI element name
  /// and the two releases in play disagree on it; whichever is absent costs one
  /// failed substring scan.
  static String stripMeasureNumbers(String svg) => _removeGroups(svg, [
    ..._allGroupRanges(svg, 'mNum'),
    ..._allGroupRanges(svg, 'measureNum'),
  ]);

  /// Removes Verovio's engraved fingerings and chord symbols, keeping the space
  /// they reserved.
  ///
  /// Prefix Verovio puts on the id of every box it emits for `svgBoundingBoxes`.
  static const _bboxIdPrefix = 'bbox-';

  static final _bboxGroupWithRect = RegExp(
    r'<g id="bbox-[^"]*" class="[^"]*bounding-box[^"]*">\s*<rect[^>]*/>\s*</g>',
  );
  static final _bboxGroupEmpty = RegExp(
    r'<g id="bbox-[^"]*" class="[^"]*bounding-box[^"]*"\s*/>',
  );

  /// Per-system ink extent in viewBox px, read from **Verovio's own** bounding
  /// boxes instead of computed from the hit map.
  ///
  /// Why this exists. `lineContentOf` unions the hit map's `measure` boxes, and
  /// those are computed client-side by `verovio_flutter`, which gets `<text>`
  /// wrong twice (see `docs/verovio-flutter-text-bbox-bug.md`): it treats the
  /// `y` attribute as the box's TOP when `y` is the BASELINE and glyphs extend
  /// UPWARD, and it falls back to a 16-unit font size because Verovio writes
  /// `font-size="0px"` on the `<text>` and puts the real size on the child
  /// `<tspan>`. Measured against Verovio's own boxes on Old Joe Clark, that puts
  /// a measure's TOP 20.6 viewBox px — 1.5 staff spaces — too low.
  ///
  /// The union's BOTTOM is wrong too, and by more: on the 6-system iPad-portrait
  /// layout it landed at 250.6 viewBox px where the rendered ink stopped at
  /// 220.5 (confirmed off the framebuffer, and Verovio's own box says 221.2) —
  /// 2.2 staff spaces of phantom depth. Honest caveat: that one is NOT explained
  /// by the `<text>` arithmetic above. Re-engraved headlessly, the union's bottom
  /// comes out 2 to 9 px too SHALLOW, the opposite sign, so something else is in
  /// play on the many-systems layouts — most likely measure-to-system
  /// assignment, which is not proven. The measurement is what the app depends on
  /// and it is now taken from Verovio, so the remaining question is academic
  /// here; it is written down so nobody re-derives half of it.
  ///
  /// Either way the bottom is what the annotation reserve was paying for. The
  /// room above a system's fingering register is read as
  /// `register - previousSystemBottom`; the phantom depth ate into it,
  /// `annotationStackFor` shrank the rows to fit what was left, and the shortfall
  /// was bought back through `spacingSystem` — where it lands as a band of white
  /// between the systems, which is what a reader notices.
  ///
  /// Verovio emits a box per LEAF (`staff`, `note`, `stem`, `beam`, `barLine`,
  /// `text`, …) and emits the CONTAINER boxes (`system`, `measure`, `layer`)
  /// empty. So a system's extent is the union of every box inside it and no
  /// class whitelist is needed: anything carrying a rect counts, which also
  /// means a future Verovio drawing something new is included for free.
  ///
  /// Coordinates. The rects live in the `definition-scale` inner viewBox, under
  /// `page-margin`'s translate, so the chain is
  /// `(y + translateY) * rootWidth / innerWidth`. All three terms are read out
  /// of this SVG rather than assumed, because they move with the engrave.
  ///
  /// Returns null when [svg] carries no boxes, so callers can fall back: test
  /// fixtures recorded before `svgBoundingBoxes` was turned on have none.
  static List<({double top, double bottom})>? systemInkBoxes(String svg) {
    if (!svg.contains('bounding-box')) return null;
    // The root <svg> comes first in the document, so firstMatch is the root and
    // not the definition-scale one nested inside it.
    final root = RegExp(
      r'<svg[^>]*viewBox="0 0 ([\d.]+) ([\d.]+)"',
    ).firstMatch(svg);
    final inner = RegExp(
      r'class="definition-scale"[^>]*viewBox="0 0 ([\d.]+) ([\d.]+)"',
    ).firstMatch(svg);
    if (root == null || inner == null) return null;
    final innerWidth = double.parse(inner.group(1)!);
    if (innerWidth <= 0) return null;
    final factor = double.parse(root.group(1)!) / innerWidth;
    final translate = RegExp(
      r'class="page-margin" transform="translate\(\s*(-?[\d.]+),\s*(-?[\d.]+)\s*\)"',
    ).firstMatch(svg);
    final dy = translate == null ? 0.0 : double.parse(translate.group(2)!);

    // `class="system">` with the closing bracket: `system bounding-box` and
    // `systemMilestoneEnd` must not match. Systems are siblings, so slicing
    // between consecutive starts gives each one its own block.
    const marker = 'class="system">';
    final starts = <int>[];
    for (var i = svg.indexOf(marker); i >= 0; i = svg.indexOf(marker, i + 1)) {
      starts.add(i);
    }
    if (starts.isEmpty) return null;

    final rectGeom = RegExp(
      r'<rect[^>]*\by="(-?[\d.]+)"[^>]*\bheight="([\d.]+)"',
    );
    final out = <({double top, double bottom})>[];
    for (var s = 0; s < starts.length; s++) {
      final end = s + 1 < starts.length ? starts[s + 1] : svg.length;
      double? top, bottom;
      for (final g in _bboxGroupWithRect.allMatches(svg, starts[s])) {
        if (g.start >= end) break;
        final r = rectGeom.firstMatch(g.group(0)!);
        if (r == null) continue;
        final y = double.parse(r.group(1)!);
        final h = double.parse(r.group(2)!);
        if (top == null || y < top) top = y;
        if (bottom == null || y + h > bottom) bottom = y + h;
      }
      // A system with no boxes at all means the option did not take; falling
      // back wholesale beats returning one bogus band among good ones.
      if (top == null || bottom == null) return null;
      out.add((top: (top + dy) * factor, bottom: (bottom + dy) * factor));
    }
    return out;
  }

  /// Cuts Verovio's `svgBoundingBoxes` groups back out. They are all one of two
  /// shallow shapes — empty, or a single `<rect/>` — and none nests a `<g>`
  /// (523 of them checked on Old Joe Clark), so a regex is sufficient here where
  /// the other strippers need balanced matching.
  static String stripBoundingBoxes(String svg) => svg
      .replaceAll(_bboxGroupWithRect, '')
      .replaceAll(_bboxGroupEmpty, '');

  /// The elements are injected precisely so Verovio will lay them out and grow
  /// the page for them; their INK is then unwanted, because the app draws its own
  /// coloured chips and bars in that space. Cutting the glyphs out of the SVG
  /// after the hit map has been read leaves the reservation intact — the layout
  /// is already decided, and `AnnotationAnchor` already recorded where each one
  /// went.
  ///
  /// Must run AFTER the hit map parse, which is why it lives here in
  /// `_buildScore` rather than in `_engraveNow`.
  static String stripAnnotationGlyphs(String svg) => _removeGroups(svg, [
    ..._allGroupRanges(svg, 'fing'),
    ..._allGroupRanges(svg, 'harm'),
  ]);

  /// Cuts [ranges] (start, end-exclusive) out of [svg], back to front so earlier
  /// indices stay valid.
  static String _removeGroups(String svg, List<(int, int)> ranges) {
    if (ranges.isEmpty) return svg;
    ranges.sort((a, b) => b.$1.compareTo(a.$1));
    var out = svg;
    for (final (start, end) in ranges) {
      out = out.substring(0, start) + out.substring(end);
    }
    return out;
  }

  /// Balanced `<g … class="[cls]">…</g>` spans for every occurrence AFTER the
  /// first (Verovio emits one per system in document order; occurrence 0 is the
  /// first system, which we keep). Balanced matching handles nested groups
  /// (e.g. a keySig's `<g class="keyAccid">` children).
  static List<(int, int)> _repeatedGroupRanges(String svg, String cls) =>
      _groupRanges(svg, cls, skipFirst: true);

  /// Every balanced `<g … class="[cls]">…</g>` span, first included.
  static List<(int, int)> _allGroupRanges(String svg, String cls) =>
      _groupRanges(svg, cls, skipFirst: false);

  /// Matches on the class TOKEN, not the whole attribute: Verovio writes
  /// `class="mNum autogenerated"` for a bar number it invented itself (as opposed
  /// to one carried by the source), and an exact-value compare silently misses
  /// precisely those — which are all of them, on an ABC or MusicXML import with
  /// no explicit numbering. The class list also shows `pageMilestoneEnd <id>` and
  /// `systemMilestoneEnd <id>` in the same two-token shape.
  static List<(int, int)> _groupRanges(
    String svg,
    String cls, {
    required bool skipFirst,
  }) {
    final out = <(int, int)>[];
    const attr = 'class="';
    var search = 0;
    var first = true;
    while (true) {
      final ci = svg.indexOf(attr, search);
      if (ci < 0) break;
      final vStart = ci + attr.length;
      final vEnd = svg.indexOf('"', vStart);
      if (vEnd < 0) break;
      if (!_hasClassToken(svg.substring(vStart, vEnd), cls)) {
        search = vEnd + 1;
        continue;
      }
      final open = svg.lastIndexOf('<g', ci);
      // The attribute must belong to THIS `<g`'s opening tag: a class on a
      // `<path>` or `<use>` would otherwise resolve back to the enclosing group
      // and take the whole system with it.
      final inOpeningTag = open >= 0 && svg.indexOf('>', open) > ci;
      if (!inOpeningTag) {
        search = vEnd + 1;
        continue;
      }
      final close = _matchCloseG(svg, open);
      search = close < 0 ? vEnd + 1 : close;
      if (first) {
        first = false;
        if (skipFirst) continue;
      }
      if (close > open) out.add((open, close));
    }
    return out;
  }

  /// Whether [attrValue] (an SVG `class` attribute's contents) carries [cls] as a
  /// whitespace-delimited token.
  static bool _hasClassToken(String attrValue, String cls) {
    if (attrValue == cls) return true;
    for (final token in attrValue.split(' ')) {
      if (token == cls) return true;
    }
    return false;
  }

  /// Index just past the `</g>` that closes the group opening at [open] (the
  /// index of its `<g`), accounting for nested `<g>`…`</g>`. Returns -1 if
  /// unbalanced.
  ///
  /// A childless group is written self-closing (`<g … />`) — Verovio's writer
  /// collapses empty nodes, and an empty `<g class="keySig"/>` is exactly what a
  /// score with no accidentals gets. Such a group ends at its own `/>`; scanning
  /// on for a `</g>` would run into the following siblings and return the close
  /// of the next non-empty one (the staff's `<g class="layer">`, i.e. every note
  /// on that system).
  static int _matchCloseG(String s, int open) {
    var depth = 0;
    var i = open;
    while (i < s.length) {
      if (s.startsWith('</g>', i)) {
        depth--;
        i += 4;
        if (depth == 0) return i;
        if (depth < 0) return -1; // closed past our own group: malformed
        continue;
      }
      if (s.startsWith('<g', i) &&
          (i + 2 >= s.length || s[i + 2] == ' ' || s[i + 2] == '>')) {
        final gt = s.indexOf('>', i);
        if (gt < 0) return -1;
        if (s[gt - 1] == '/') {
          // Self-closing `<g/>` opens nothing. If it's the group we were asked
          // about, its own tag is the whole range.
          if (i == open) return gt + 1;
        } else {
          depth++;
        }
        i = gt + 1;
        continue;
      }
      i++;
    }
    return -1;
  }

  /// Tab view (fingering mode): replace each rendered tab fret number with the
  /// corresponding violin fingering label. Verovio's `tab.guitar` engraving
  /// draws frets as `<text><tspan>DIGIT</tspan></text>` inside a
  /// `<g class="note">` (melody noteheads are `<use>` glyphs, never `<text>`),
  /// so the Nth such group in document order is the Nth tab note — matching the
  /// order of [labels] from `TabScoreGenerator`. `text-anchor="middle"` keeps a
  /// multi-character label (e.g. "2L") centered.
  static final _tabFretRe = RegExp(
    r'(<g id="[^"]+" class="note">\s*<text\b[^>]*>\s*<tspan\b[^>]*>)([^<]*)(</tspan>)',
    dotAll: true,
  );

  static String _swapTabFingerings(String svg, List<String> labels) {
    var i = 0;
    return svg.replaceAllMapped(_tabFretRe, (m) {
      final label = i < labels.length ? labels[i] : m.group(2)!;
      i++;
      return '${m.group(1)}$label${m.group(3)}';
    });
  }

  /// Ids of every note/rest element on a tab (second) staff. The SVG nests
  /// `measure > staff > layer`; each measure emits its staves in order, so the
  /// odd-indexed `<g class="staff">` groups (0-based) are the tab staff. Returns
  /// the ids of the `<g class="note">`/`<g class="rest">` within those groups.
  static Set<String> _tabStaffElementIds(String svg) {
    final ids = <String>{};
    final elemRe = RegExp(r'<g id="([^"]+)" class="(?:note|rest)"');
    var search = 0;
    var staffIndex = 0;
    while (true) {
      final ci = svg.indexOf('class="staff"', search);
      if (ci < 0) break;
      final open = svg.lastIndexOf('<g', ci);
      final close = open < 0 ? -1 : _matchCloseG(svg, open);
      search = close < 0 ? ci + 13 : close;
      if (open < 0 || close < 0) {
        staffIndex++;
        continue;
      }
      if (staffIndex.isOdd) {
        for (final m in elemRe.allMatches(svg.substring(open, close))) {
          ids.add(m.group(1)!);
        }
      }
      staffIndex++;
    }
    return ids;
  }

  /// jovial_svg shim: jovial parses `<style>`/`currentColor` (the two things
  /// flutter_svg dropped), so the only normalization needed is collapsing
  /// Verovio's nested `<svg class="definition-scale" viewBox="0 0 18000 …">`
  /// into a `<g transform="scale(...)">` — jovial throws "Second `<svg>` tag in
  /// file". The CSS `<style>` block is preserved verbatim. Returns the SVG
  /// ready for `ScalableImage.fromSvgString(..., currentColor: Colors.black)`.
  static String flattenForRenderer(String svg) {
    var out = svg;
    final outerVb = RegExp(
      r'<svg[^>]*viewBox="0 0 ([\d.]+) ([\d.]+)"',
    ).firstMatch(out);
    final innerOpen = RegExp(
      r'<svg class="definition-scale"[^>]*viewBox="0 0 ([\d.]+) ([\d.]+)"[^>]*>',
    ).firstMatch(out);
    if (outerVb != null && innerOpen != null) {
      final ow = double.parse(outerVb.group(1)!);
      final oh = double.parse(outerVb.group(2)!);
      final iw = double.parse(innerOpen.group(1)!);
      final ih = double.parse(innerOpen.group(2)!);
      final sx = (ow / iw).toStringAsFixed(6);
      final sy = (oh / ih).toStringAsFixed(6);
      out = out.replaceFirst(
        innerOpen.group(0)!,
        '<g transform="scale($sx, $sy)">',
      );
      // First </svg> closes the (removed) inner svg; outer </svg> stays.
      out = out.replaceFirst('</svg>', '</g>');
    }
    out = _unscopeStyleSelectors(out);
    return out;
  }

  /// Rewrites Verovio's ID-scoped CSS selectors into bare element selectors.
  ///
  /// Verovio namespaces its stylesheet with the root SVG's generated id so that
  /// several scores on one HTML page can't bleed into each other:
  ///
  /// ```css
  /// #jspm2ir ellipse, #jspm2ir path, … {stroke:currentColor}
  /// ```
  ///
  /// jovial_svg cannot match that. Its stylesheet is keyed by tag name or by
  /// `#id` only (`svg_parser.dart` splits a selector on `.` and nothing else), so
  /// a descendant selector becomes a key like `"#jspm2ir path"` that no lookup
  /// ever asks for — the rule is silently dropped.
  ///
  /// That matters because staff lines, stems and barlines are bare
  /// `<path d="…" stroke-width="13"/>` with no stroke attribute of their own:
  /// this rule is the only thing that makes them visible. They happen to render
  /// anyway under Skia (host and iOS) but not under CanvasKit on web, so the
  /// stylesheet has to actually apply rather than be relied on by accident.
  ///
  /// We render exactly one score per widget, so the id namespacing is redundant
  /// and dropping it yields `ellipse, path, … {stroke:currentColor}` — selectors
  /// jovial keys by tag name and applies. Scoped strictly to the `<style>` block
  /// so `xlink:href="#E050-…"` glyph references are untouched.
  static String _unscopeStyleSelectors(String svg) {
    return svg.replaceAllMapped(
      RegExp(r'<style\b[^>]*>(.*?)</style>', dotAll: true),
      (m) {
        final body = m
            .group(1)!
            .replaceAllMapped(
              // `#<id>` followed by whitespace and then a tag name.
              RegExp(r'#[A-Za-z][\w-]*\s+(?=[A-Za-z])'),
              (_) => '',
            );
        return m.group(0)!.replaceFirst(m.group(1)!, body);
      },
    );
  }

  Future<void> dispose() async {
    final svc = _svc;
    _svc = null;
    _cache.clear();
    await svc?.dispose();
  }
}

/// Where Verovio put one of its own annotations — and nothing else.
///
/// The position only, deliberately. The hit map's reported WIDTH and HEIGHT for
/// any text element are meaningless: its walker has no `<tspan>` handling and
/// reads `font-size` off the `<text>`, which Verovio always writes as `"0px"`, so
/// it falls back to 16 units and describes a ~0.6x0.7px box for a glyph that
/// really inks ~12px. The `x` and `y` attributes, by contrast, are read straight
/// off the element and correctly transformed, so they are exact.
///
/// That asymmetry is fine, because size is not wanted here: annotation type is
/// sized from the staff space by `annotationFontSizeFor`, which is
/// scale-invariant and independent of anything Verovio chose. What is wanted is
/// the one thing only Verovio knows — how far it pushed the annotation off the
/// staff, and therefore how much room it reserved.
///
/// `x` is the glyph's horizontal ANCHOR, which is its centre for `fing`
/// (`text-anchor="middle"`) and its left edge for `harm`. Nothing reads it today;
/// the fingering chips take their x from the notehead they belong to, via
/// `noteAt`, so a chip stays put whether or not the engrave carried fingerings.
/// It is kept because it is the honest record of what the engraver said.
///
/// Pinned by `test/verovio_annotation_anchor_test.dart` against real Verovio
/// output, so a toolkit or plugin upgrade that changes any of this fails there
/// rather than quietly moving the annotations.
typedef AnnotationAnchor = ({int line, double x, double y});

/// One engraved page: the renderer-ready SVG plus geometric anchors in page
/// viewBox coordinates. Domain-free — anchors carry document indices, which the
/// widget maps to model measure numbers via its `measureNumbers` list.
@immutable
class EngravedScore {
  final Size viewBox;

  /// SVG flattened for jovial_svg (see [VerovioEngraver.flattenForRenderer]).
  final String svg;

  /// Every captured element id → its bbox (viewBox coords).
  final Map<String, Rect> bboxById;

  /// Measures in document order.
  final List<MeasureAnchor> measures;

  /// Notes & rests, each tagged with its measure index and positional index
  /// within that measure (rests counted — matching `HighlightEvent.noteIndex`).
  final List<NoteAnchor> notes;

  /// Engraved meter signatures (viewBox coords) in document order — normally one,
  /// on the first system. The count-in display anchors to these; see
  /// [meterSigOnLine].
  final List<Rect> meterSigs;

  /// Per measure index → its system-line index.
  final List<int> measureLine;

  /// One tiled vertical band per system line (viewBox coords); adjacent bands
  /// touch with zero gap/overlap. Index with [measureLine].
  final List<({double top, double bottom})> lineBands;

  /// Per system line, the RAW content extent (viewBox coords) — the union of that
  /// line's measure boxes. Unlike [lineBands] these are not tiled, so
  /// `lineContent[l].top - lineContent[l-1].bottom` is the true whitespace
  /// between two systems.
  final List<({double top, double bottom})> lineContent;

  /// Where Verovio engraved its own fingerings and chord symbols, per system.
  /// Empty when the engrave carried none. See [AnnotationAnchor], and
  /// [fingRegister] / [harmRegister] for the register these collapse to.
  final List<AnnotationAnchor> fingAnchors;
  final List<AnnotationAnchor> harmAnchors;

  /// The Verovio `pageWidth` (MEI units) this score was laid out for. Together
  /// with the achieved measures-per-line it yields the piece's scale-invariant
  /// `unitsPerMeasure` — see `staff_zoom.dart`.
  final int pageWidthUnits;

  final int renderMs;

  const EngravedScore({
    required this.viewBox,
    required this.svg,
    required this.bboxById,
    required this.measures,
    required this.notes,
    required this.measureLine,
    required this.lineBands,
    required this.lineContent,
    required this.pageWidthUnits,
    this.fingAnchors = const [],
    this.harmAnchors = const [],
    required this.renderMs,
    this.meterSigs = const [],
  });

  /// Number of system lines engraved.
  int get lineCount => lineBands.length;

  /// The register line for system [l]: the topmost baseline Verovio used for
  /// that class of annotation on that system, or null when it engraved none
  /// there.
  ///
  /// The TOPMOST rather than the mean, because a drawn label grows upward from
  /// its baseline: sitting every label on the highest baseline the engraver
  /// chose puts the row clear of every notehead on the system, which drawing at
  /// the mean would not. Verovio anchors each fingering to its own note, so the
  /// baselines vary a little with pitch — measured at 1.7-1.8 staff spaces of
  /// spread, against a hard floor of +0.61 spaces above the staff. Chord symbols
  /// already share one baseline exactly, so for those this is a no-op.
  ///
  /// Per system, which is the whole point: the old `laneSqueeze` took the
  /// tightest gap in the entire score, so one cramped system flattened every
  /// label on every other one.
  double? fingRegister(int l) => _register(fingAnchors, l);
  double? harmRegister(int l) => _register(harmAnchors, l);

  /// Where to draw the chord bar on system [l] — [harmRegister], or the system's
  /// own ink top when Verovio engraved no chord symbol there.
  ///
  /// The fallback is not an edge case. MusicXML declares `<harmony>` only where
  /// the chord CHANGES, so a run that carries across a system break leaves the
  /// continuation system with nothing engraved: measured on Old Joe Clark at three
  /// measures a line, the A established in bar 9 continues through bars 10-12 and
  /// that whole system had `harmRegister == null`, so every segment handed to the
  /// chord painter was skipped and the bar simply wasn't there. The run itself was
  /// fine — runs come from the parsed model, not the engraved xml — it had no
  /// anchor to hang on.
  ///
  /// The ink top is the right stand-in because on every system that DOES carry a
  /// chord symbol, that symbol IS the ink top (measured: the register sits exactly
  /// at `lineContent[l].top` on all of them, since it is the highest thing
  /// Verovio drew). So the bar keeps the same relationship to the music either
  /// way.
  ///
  /// The cost, stated plainly: on a continuation system the ink top is the topmost
  /// NOTE rather than a chord symbol, so a system with a high note carries its bar
  /// a little higher than its neighbours. Uneven, but present — and a missing bar
  /// reads as a bug where a slightly high one does not. Pinning it to the staff
  /// instead would need a staff reference this class does not carry: the
  /// `class="staff"` bbox includes the notes, so it is not one.
  double? chordRegister(int l) =>
      harmRegister(l) ??
      (l >= 0 && l < lineContent.length ? lineContent[l].top : null);

  static double? _register(List<AnnotationAnchor> anchors, int l) {
    double? top;
    for (final a in anchors) {
      if (a.line != l) continue;
      if (top == null || a.y < top) top = a.y;
    }
    return top;
  }

  /// The Verovio `scale` this score came out of, recovered from its own geometry:
  /// the page is `pageWidthUnits` MEI units wide and renders `viewBox.width`
  /// pixels wide, and `viewBox.width = pageWidthUnits × scale / 100`.
  ///
  /// Derived rather than stored so it cannot disagree with the SVG it describes.
  double get engravedScale =>
      pageWidthUnits <= 0 ? 0 : viewBox.width * 100 / pageWidthUnits;

  /// Height of the five-line staff, in viewBox px. See `staffHeightUnits`.
  double get staffHeightViewBox => staffHeightUnits * engravedScale / 100;

  /// One staff space, in viewBox px — **the yardstick for annotation type**.
  ///
  /// A notehead is one space tall, so this is the size the reader compares a
  /// fingering digit or a chord label against. Note what it is NOT:
  /// [contentHeightViewBox], which the lane heights are fractions of, is the
  /// system's whole INK extent and therefore moves with the melody's range — a
  /// tune with wide leaps has a taller content box and would get bigger labels
  /// for no reason the reader can see. Type size should follow the staff.
  double get staffSpaceViewBox => staffHeightViewBox / 4;

  /// Average height of one system in viewBox coordinates, gap included. The
  /// bands tile the content, so their mean is content-height / lines — the right
  /// per-system figure for predicting how tall another layout would be. Falls
  /// back to the whole viewBox when there are no bands.
  ///
  /// NOTE the units: viewBox coordinates, i.e. **logical pixels at the scale
  /// this score was engraved at** (the page is engraved to the render width, so
  /// `viewBox.width ≈ widthPx`). It is NOT in MEI units and it is NOT
  /// scale-invariant — a consumer must divide by the engraving scale to compare
  /// across zoom levels. See `staff_zoom.dart`.
  double get systemHeightViewBox {
    if (lineBands.isEmpty) return viewBox.height;
    var sum = 0.0;
    for (final b in lineBands) {
      sum += b.bottom - b.top;
    }
    return sum / lineBands.length;
  }

  /// Mean height of one system's INK (viewBox coords), gap excluded — the mean of
  /// [lineContent]. Unlike [systemHeightViewBox] this doesn't move when the staff
  /// spacing preference changes, which makes it the right yardstick for sizing
  /// decorations: the chord lane should track the note size, not the gap.
  double get contentHeightViewBox {
    if (lineContent.isEmpty) return viewBox.height;
    var sum = 0.0;
    for (final c in lineContent) {
      sum += c.bottom - c.top;
    }
    return sum / lineContent.length;
  }

  MeasureAnchor? measureAt(int index) =>
      (index < 0 || index >= measures.length) ? null : measures[index];

  /// The system line a measure sits on, or -1 if out of range.
  int lineOfMeasure(int index) =>
      (index < 0 || index >= measureLine.length) ? -1 : measureLine[index];

  /// The tiled vertical band (top/bottom, viewBox coords) for a measure's
  /// system line, or null if out of range.
  ({double top, double bottom})? bandForMeasure(int index) {
    final l = lineOfMeasure(index);
    return (l < 0 || l >= lineBands.length) ? null : lineBands[l];
  }

  /// The meter signature engraved on system line [l], or null when that line has
  /// none — which is every line but the first, since Verovio only re-states the
  /// meter where it changes.
  ///
  /// Matched by vertical overlap rather than by index, so a mid-piece meter
  /// change resolves to whichever system actually carries it.
  Rect? meterSigOnLine(int l) {
    if (l < 0 || l >= lineContent.length) return null;
    final c = lineContent[l];
    for (final r in meterSigs) {
      if (r.center.dy >= c.top && r.center.dy <= c.bottom) return r;
    }
    return null;
  }

  /// Anchor for the note at document measure [measureIndex], positional
  /// [noteIndex]. Null when out of range (e.g. a stale highlight).
  NoteAnchor? noteAt(int measureIndex, int noteIndex) {
    for (final n in notes) {
      if (n.measureIndex == measureIndex && n.noteIndex == noteIndex) return n;
    }
    return null;
  }
}

@immutable
class MeasureAnchor {
  final int index; // document order
  final String id;
  final Rect rect; // viewBox coords
  const MeasureAnchor({
    required this.index,
    required this.id,
    required this.rect,
  });
}

@immutable
class NoteAnchor {
  final String id;
  final int measureIndex;
  final int noteIndex; // positional within measure, rests counted
  final bool isRest;
  final Rect rect; // viewBox coords
  final double? beatPosition; // whole-note units (qstamp/4), if known
  const NoteAnchor({
    required this.id,
    required this.measureIndex,
    required this.noteIndex,
    required this.isRest,
    required this.rect,
    this.beatPosition,
  });

  Offset get center => rect.center;
}

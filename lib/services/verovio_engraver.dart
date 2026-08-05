import 'dart:convert';
import 'dart:ui' show Rect, Size, Offset;

import 'package:flutter/foundation.dart';
import 'package:verovio_flutter/verovio_flutter.dart';

import 'staff_zoom.dart'
    show
        lineContentOf,
        measuresPerLineOf,
        staffScaleProbe,
        systemLinesOf,
        verovioLaneMarginUnits,
        verovioLaneSpacingUnits,
        verovioPageMarginTopDefault;

/// Native staff engraving via the Verovio toolkit (FFI worker isolate).
///
/// Verovio does layout/coordinates; a Flutter renderer (jovial_svg) draws the
/// returned SVG and native overlays draw selection/highlight/cursor on top.
/// See `docs/verovio_custompaint_migration_plan.md`.
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
  static const _hitMapConfig = ParseConfig(
      captureClasses: {'note', 'rest', 'measure', 'meterSig'});

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
      final resourcePath = await VerovioResourceManager.ensureVerovioAssetsReady();
      final svc = await VerovioAsyncService.spawn(resourcePath: resourcePath);
      _svc = svc;
      _spawning = null;
      return svc;
    }();
  }

  /// Width bucket so sub-pixel resize jitter doesn't re-engrave. ~48px steps.
  static int _bucketOf(double widthPx) => (widthPx / 48).round();

  static String _keyFor(String xml, double widthPx, double scale, String variant) =>
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
  /// - [mnumInterval]: bar-number interval; pass the measures-per-line target so
  ///   each system starts with a number.
  /// - [spacingSystem]: vertical gap between systems in MEI units — the
  ///   Verovio-side home of the "Staff spacing" preference. Verovio's own default
  ///   is 12; see `verovioSpacingSystemFor`.
  /// - [laneCount]: how many annotation lanes to leave room for above each
  ///   system. 1 (the default) engraves exactly as before; 2 widens the gap and
  ///   the top margin by one lane so the annotation view's fingering channel and
  ///   the chord lane both fit. It is a LAYOUT input, not a decoration — which is
  ///   why a lane count change has to re-engrave.
  Future<EngravedScore> engrave(
    String musicXml, {
    required double widthPx,
    double scale = staffScaleProbe,
    int pageHeightUnits = 60000,
    int mnumInterval = 4,
    int spacingSystem = 12,
    int laneCount = 1,
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
  }) {
    final variant = '${stripRepeatClefs ? 1 : 0}${tabMode ? 1 : 0}'
        '|$pageHeightUnits|$mnumInterval|$spacingSystem|$laneCount|'
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
      final score = await _engraveNow(musicXml,
          widthPx: widthPx,
          scale: scale,
          pageHeightUnits: pageHeightUnits,
          mnumInterval: mnumInterval,
          spacingSystem: spacingSystem,
          laneCount: laneCount,
          tabFingerLabels: tabFingerLabels,
          tabMode: tabMode,
          stripRepeatClefs: stripRepeatClefs);
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
    int laneCount = 1,
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
  }) async {
    final svc = await _ensureService();
    final sw = Stopwatch()..start();

    // pageWidth is in MEI units; rendered viewBox px ≈ pageWidth * scale / 100.
    final pageWidthUnits = (widthPx * 100 / scale).round();
    // Room for annotation lanes past the first, in the two kinds of whitespace
    // the lanes live in. Separately calibrated — a `spacingSystem` unit buys ~9×
    // more room than a `pageMarginTop` one. See `staff_zoom.dart`.
    final laneGap = verovioLaneSpacingUnits(laneCount);
    final laneMargin = verovioLaneMarginUnits(laneCount);
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
      'breaks': 'auto',
      'footer': 'none',
      'header': 'none',
      'mnumInterval': mnumInterval,
      // Vertical gap between systems — the "Staff spacing" preference, plus room
      // for any annotation lane past the first.
      'spacingSystem': spacingSystem + laneGap,
      // Line 0's lanes sit in the page's top margin, which has no gap above it
      // to borrow from.
      'pageMarginTop': verovioPageMarginTopDefault + laneMargin,
      'svgViewBox': true, // root viewBox so the renderer can scale
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
      laneCount: laneCount,
      tabFingerLabels: tabFingerLabels,
      tabMode: tabMode,
      stripRepeatClefs: stripRepeatClefs,
    );
    if (debugLogging) {
      debugPrint('[engraver] engraved viewBox=${score.viewBox.width.toInt()}'
          '×${score.viewBox.height.toInt()} measures=${score.measures.length} '
          'notes=${score.notes.length} scale=${scale.toStringAsFixed(1)} '
          'pageW=$pageWidthUnits lines=${score.lineCount} '
          'mpl=${measuresPerLineOf(score.measureLine)} ${score.renderMs}ms');
      // Lane calibration: is there whitespace above line 0 (page margin) and
      // between systems (spacingSystem) for a full-height bar in every lane?
      // `squeeze` is the number to watch — 1.00 means every lane got its full
      // proportional height, anything less means the reservation didn't land and
      // the fallback is doing the work.
      final c = score.lineContent;
      debugPrint('[engraver] lane contentH=${score.contentHeightViewBox.toStringAsFixed(1)} '
          'lanes=${score.laneCount} '
          'squeeze=${score.laneSqueeze.toStringAsFixed(2)} '
          'chordH=${score.annotationLaneHeight(score.laneCount - 1).toStringAsFixed(1)} '
          'fingerH=${score.annotationLaneHeight(0).toStringAsFixed(1)} '
          'top0=${c.isEmpty ? -1 : c.first.top.toStringAsFixed(1)} '
          'gap1=${c.length > 1 ? (c[1].top - c[0].bottom).toStringAsFixed(1) : '-'} '
          'sysH=${score.systemHeightViewBox.toStringAsFixed(1)}');
    }
    return score;
  }

  EngravedScore _buildScore({
    required String svg,
    required PageHitMap hitMap,
    required Map<String, double> qstampById,
    required int pageWidthUnits,
    required int renderMs,
    int laneCount = 1,
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
  }) {
    final bboxById = <String, Rect>{
      for (final h in hitMap.byType) h.id: h.bbox,
    };

    // Measures in document order (byType preserves DFS / document order).
    final measureHits =
        hitMap.byType.where((h) => h.type == 'measure').toList();
    final measures = <MeasureAnchor>[
      for (var i = 0; i < measureHits.length; i++)
        MeasureAnchor(index: i, id: measureHits[i].id, rect: measureHits[i].bbox),
    ];

    // Tab view: the second staff duplicates the melody. Exclude its notes/rests
    // from the anchors so positional noteIndex (and thus the highlight/cursor,
    // which map a model note → anchor) stays on the melody staff.
    final tabIds = tabMode ? _tabStaffElementIds(svg) : const <String>{};

    // Assign each note/rest to the measure whose bbox contains its center,
    // then rank within the measure by x to get our positional noteIndex
    // (which counts rests). This is robust to qstamp/tick alignment quirks.
    final noteHits = hitMap.byType
        .where((h) => (h.type == 'note' || h.type == 'rest') &&
            !tabIds.contains(h.id))
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
        notes.add(NoteAnchor(
          id: h.id,
          measureIndex: entry.key,
          noteIndex: ni,
          isRest: h.type == 'rest',
          rect: h.bbox,
          // beatPosition is in whole-note units (our HighlightEvent convention);
          // Verovio qstamp is in quarter-note units → divide by 4.
          beatPosition: q == null ? null : q / 4,
        ));
      }
    }

    // Meter signatures in document order. Normally exactly one (Verovio engraves
    // it on the first system only unless the meter changes mid-piece), so the
    // count-in anchors to `meterSigs.first` and falls back to a measure's left
    // edge when the score has none.
    final meterSigs = <Rect>[
      for (final h in hitMap.byType)
        if (h.type == 'meterSig') h.bbox,
    ];

    final measureRects = [for (final m in measures) m.rect];
    final (measureLine, lineBands) = systemLinesOf(measureRects);
    final lineContent = lineContentOf(measureRects, measureLine);

    var processedSvg = stripRepeatClefs ? _clefKeySigFirstSystemOnly(svg) : svg;
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
      pageWidthUnits: pageWidthUnits,
      renderMs: renderMs,
      laneCount: laneCount,
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

  /// Keeps the clef + key signature only on the FIRST system, stripping the
  /// copies Verovio re-engraves at the start of every subsequent system. This
  /// is a deliberate departure from standard engraving (which repeats them per
  /// line) for this single-staff practice view. The notes keep their engraved
  /// x positions, so later systems carry a small leading indent where the
  /// removed glyphs were — hitMap coordinates are untouched, so overlays,
  /// the cursor, and taps stay aligned.
  static String _clefKeySigFirstSystemOnly(String svg) {
    final ranges = <(int, int)>[
      ..._repeatedGroupRanges(svg, 'clef'),
      ..._repeatedGroupRanges(svg, 'keySig'),
    ];
    if (ranges.isEmpty) return svg;
    // Remove back-to-front so earlier indices stay valid.
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
  static List<(int, int)> _repeatedGroupRanges(String svg, String cls) {
    final out = <(int, int)>[];
    final marker = 'class="$cls"';
    var search = 0;
    var first = true;
    while (true) {
      final ci = svg.indexOf(marker, search);
      if (ci < 0) break;
      final open = svg.lastIndexOf('<g', ci);
      final close = open < 0 ? -1 : _matchCloseG(svg, open);
      search = close < 0 ? ci + marker.length : close;
      if (first) {
        first = false;
        continue;
      }
      if (open >= 0 && close > open) out.add((open, close));
    }
    return out;
  }

  /// Index just past the `</g>` that closes the group opening at [open] (the
  /// index of its `<g`), accounting for nested `<g>`…`</g>`. Returns -1 if
  /// unbalanced.
  static int _matchCloseG(String s, int open) {
    var depth = 0;
    var i = open;
    while (i < s.length) {
      if (s.startsWith('</g>', i)) {
        depth--;
        i += 4;
        if (depth == 0) return i;
        continue;
      }
      if (s.startsWith('<g', i) &&
          (i + 2 >= s.length || s[i + 2] == ' ' || s[i + 2] == '>')) {
        final gt = s.indexOf('>', i);
        if (gt < 0) return -1;
        if (s[gt - 1] != '/') depth++; // self-closing `<g/>` opens nothing
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
      dotAll: true);

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
    final outerVb =
        RegExp(r'<svg[^>]*viewBox="0 0 ([\d.]+) ([\d.]+)"').firstMatch(out);
    final innerOpen = RegExp(
            r'<svg class="definition-scale"[^>]*viewBox="0 0 ([\d.]+) ([\d.]+)"[^>]*>')
        .firstMatch(out);
    if (outerVb != null && innerOpen != null) {
      final ow = double.parse(outerVb.group(1)!);
      final oh = double.parse(outerVb.group(2)!);
      final iw = double.parse(innerOpen.group(1)!);
      final ih = double.parse(innerOpen.group(2)!);
      final sx = (ow / iw).toStringAsFixed(6);
      final sy = (oh / ih).toStringAsFixed(6);
      out = out.replaceFirst(
          innerOpen.group(0)!, '<g transform="scale($sx, $sy)">');
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
        final body = m.group(1)!.replaceAllMapped(
            // `#<id>` followed by whitespace and then a tag name.
            RegExp(r'#[A-Za-z][\w-]*\s+(?=[A-Za-z])'), (_) => '');
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
  /// between two systems. See [annotationLaneBand].
  final List<({double top, double bottom})> lineContent;

  /// How many annotation lanes the whitespace above each system is divided into.
  ///
  /// 1 for the staff and tab views (the chord lane alone). 2 for the annotation
  /// view, which stacks a fingering channel below the chord lane. The engrave
  /// reserves extra room for every lane past the first
  /// ([verovioLaneReserveUnits]), so this has to be fixed BEFORE the layout —
  /// which is why it's a property of the engraved score rather than something a
  /// painter can decide.
  final int laneCount;

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
    required this.renderMs,
    this.meterSigs = const [],
    this.laneCount = 1,
  });

  /// Number of system lines engraved.
  int get lineCount => lineBands.length;

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

  /// Annotation-lane heights and clearance, as fractions of
  /// [contentHeightViewBox]. Kept proportional so a lane scales with the notes at
  /// every zoom level, the same principle as `_OverlayPainter._bandPx`.
  ///
  /// The two lanes are deliberately NOT the same height. A chord bar carries
  /// `IV (G)` and is read as a span; a fingering chip carries `2L` and is read as
  /// a point, so it can be shorter and still be the more legible of the two. That
  /// isn't only cosmetic: every fraction spent here has to be bought back as
  /// inter-system gap, and gap is what pushes a piece past the auto-fit budget
  /// (see `verovioLaneSpacingUnits`). The channel is as short as it can be and
  /// still hold a two-character chip.
  static const chordLaneHeightFraction = 0.30;
  static const fingeringLaneHeightFraction = 0.22;
  static const annotationLanePadFraction = 0.05;

  /// Lane height fractions bottom-up: `[fingering, chord]` with a channel,
  /// `[chord]` without. A 1-lane score is therefore bit-for-bit what it was
  /// before lanes could stack.
  List<double> get _laneFractions => laneCount >= 2
      ? const [fingeringLaneHeightFraction, chordLaneHeightFraction]
      : const [chordLaneHeightFraction];

  /// How much the lanes had to be squeezed to fit the whitespace: 1.0 when they
  /// all got their full proportional height, less when they didn't.
  ///
  /// The squeeze is the safety net, not the mechanism. A score engraved for N
  /// lanes has already been given room for them ([verovioLaneSpacingUnits] /
  /// [verovioLaneMarginUnits]) — this only bites when that reservation didn't land
  /// (a very tight staff spacing, or a Verovio that ignored the options), and then
  /// it degrades to thinner lanes rather than lanes drawn over the notes.
  ///
  /// Uniform across systems, so the lanes read as one consistent register rather
  /// than growing and shrinking with each gap: the room is the TIGHTEST the score
  /// offers — the page's top margin above line 0, the inter-system gap everywhere
  /// else.
  double get laneSqueeze {
    if (lineContent.isEmpty) return 0;
    final yard = contentHeightViewBox;
    if (yard <= 0) return 0;
    final pad = yard * annotationLanePadFraction;
    var room = lineContent[0].top; // page margin; nothing above it to clear
    for (var l = 1; l < lineContent.length; l++) {
      final gap = lineContent[l].top - lineContent[l - 1].bottom - pad;
      if (gap < room) room = gap;
    }
    final avail = room - pad;
    if (avail <= 0) return 0;
    var want = 0.0;
    for (final f in _laneFractions) {
      want += f * yard;
    }
    if (want <= 0) return 0;
    return avail < want ? avail / want : 1.0;
  }

  /// Height (viewBox px) of annotation lane [slot], counting from the ink up.
  double annotationLaneHeight(int slot) {
    final fractions = _laneFractions;
    if (slot < 0 || slot >= fractions.length) return 0;
    return contentHeightViewBox * fractions[slot] * laneSqueeze;
  }

  /// Vertical band (viewBox coords) for annotation lane [slot] on system line
  /// [l], or null when there is no usable room.
  ///
  /// Slot 0 sits directly above the line's ink (past the clearance pad); each
  /// higher slot stacks on top of the one below it. So in the annotation view the
  /// fingering channel (slot 0) is the one adjacent to the notes it describes,
  /// and the chord lane (the top slot) stays where it has always been relative to
  /// the reader — furthest from the staff.
  ({double top, double bottom})? annotationLaneBand(int l, int slot) {
    if (l < 0 || l >= lineContent.length) return null;
    final fractions = _laneFractions;
    if (slot < 0 || slot >= fractions.length) return null;
    final h = annotationLaneHeight(slot);
    if (h <= 0) return null;
    var bottom =
        lineContent[l].top - contentHeightViewBox * annotationLanePadFraction;
    for (var s = 0; s < slot; s++) {
      bottom -= annotationLaneHeight(s);
    }
    return (top: bottom - h, bottom: bottom);
  }

  /// The chord-run lane: always the TOP slot, so adding a fingering channel
  /// below it doesn't move the chords.
  ({double top, double bottom})? chordLaneBand(int l) =>
      annotationLaneBand(l, _laneFractions.length - 1);

  /// The fingering channel: slot 0, directly above the notes. Null in a score
  /// engraved without a channel (`laneCount == 1`), so a caller can't
  /// accidentally draw one into space that was never reserved.
  ({double top, double bottom})? fingeringLaneBand(int l) =>
      laneCount < 2 ? null : annotationLaneBand(l, 0);

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
  const MeasureAnchor({required this.index, required this.id, required this.rect});
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

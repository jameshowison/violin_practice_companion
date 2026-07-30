import 'dart:convert';
import 'dart:ui' show Rect, Size, Offset;

import 'package:flutter/foundation.dart';
import 'package:verovio_flutter/verovio_flutter.dart';
import 'package:xml/xml.dart';

import '../models/note_event.dart' show KeyMode;
import 'chord_analysis.dart';
import 'musicxml_parser.dart';

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

  // Small LRU-ish cache keyed by (xmlHash, widthBucket, scale). Reflow on
  // rotation/resize and the live measure editor re-engrave hit the cache when
  // the inputs are unchanged.
  final _cache = <String, EngravedScore>{};
  static const _maxCache = 8;

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
  Future<EngravedScore> engrave(
    String musicXml, {
    required double widthPx,
    double scale = 40,
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
  }) {
    final variant = '${stripRepeatClefs ? 1 : 0}${tabMode ? 1 : 0}'
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
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
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
      // clips the bottom of the score in portrait (narrow → many systems). A
      // huge page guarantees one page; adjustPageHeight then crops the slack.
      'pageHeight': 60000,
      'adjustPageHeight': true,
      'breaks': 'auto',
      'footer': 'none',
      'header': 'none',
      'mnumInterval': 4, // measure numbers every 4 bars
      'svgViewBox': true, // root viewBox so the renderer can scale
    };
    await svc.setOptionsJson(jsonEncode(options));
    await svc.loadData(stripPartLabels(musicXml));

    final res = await svc.renderPageWithHitMap(1);
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
      renderMs: sw.elapsedMilliseconds,
      tabFingerLabels: tabFingerLabels,
      tabMode: tabMode,
      stripRepeatClefs: stripRepeatClefs,
      harmLabels: _computeHarmLabels(musicXml),
    );
    if (debugLogging) {
      debugPrint('[engraver] engraved viewBox=${score.viewBox.width.toInt()}'
          '×${score.viewBox.height.toInt()} measures=${score.measures.length} '
          'notes=${score.notes.length} ${score.renderMs}ms');
    }
    return score;
  }

  EngravedScore _buildScore({
    required String svg,
    required PageHitMap hitMap,
    required Map<String, double> qstampById,
    required int renderMs,
    List<String>? tabFingerLabels,
    bool tabMode = false,
    bool stripRepeatClefs = true,
    List<String> harmLabels = const [],
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

    final (measureLine, lineBands) = _computeLineBands(measures);

    var processedSvg = stripRepeatClefs ? _clefKeySigFirstSystemOnly(svg) : svg;
    if (tabFingerLabels != null) {
      processedSvg = _swapTabFingerings(processedSvg, tabFingerLabels);
    }
    if (harmLabels.isNotEmpty) {
      processedSvg = _swapHarmLabels(processedSvg, harmLabels);
    }
    processedSvg = flattenForRenderer(processedSvg);

    return EngravedScore(
      viewBox: hitMap.viewBox,
      svg: processedSvg,
      bboxById: bboxById,
      measures: measures,
      notes: notes,
      measureLine: measureLine,
      lineBands: lineBands,
      renderMs: renderMs,
    );
  }

  /// Groups measures into system lines (a new line where the engraved x resets
  /// leftward) and returns, per measure, its line index plus a set of **tiled**
  /// vertical bands — one per line — whose boundaries sit at the midpoint
  /// between adjacent lines' content. Tiling guarantees consecutive lines touch
  /// with zero gap and zero overlap, so a full-height section/selection wash
  /// reads as clean, even bands regardless of note heights.
  static (List<int>, List<({double top, double bottom})>) _computeLineBands(
      List<MeasureAnchor> measures) {
    if (measures.isEmpty) return (const [], const []);
    final measureLine = List<int>.filled(measures.length, 0);
    final contentTop = <double>[];
    final contentBottom = <double>[];
    var line = -1;
    var prevLeft = double.negativeInfinity;
    for (var i = 0; i < measures.length; i++) {
      final r = measures[i].rect;
      if (line < 0 || r.left < prevLeft - 1) {
        line++;
        contentTop.add(r.top);
        contentBottom.add(r.bottom);
      } else {
        if (r.top < contentTop[line]) contentTop[line] = r.top;
        if (r.bottom > contentBottom[line]) contentBottom[line] = r.bottom;
      }
      measureLine[i] = line;
      prevLeft = r.left;
    }
    final n = contentTop.length;
    final bands = <({double top, double bottom})>[
      for (var l = 0; l < n; l++)
        (
          top: l == 0 ? contentTop[0] : (contentBottom[l - 1] + contentTop[l]) / 2,
          bottom: l == n - 1
              ? contentBottom[n - 1]
              : (contentBottom[l] + contentTop[l + 1]) / 2,
        )
    ];
    return (measureLine, bands);
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

  /// Chord-symbol labels (degree-primary, e.g. "I (A)") for each `<harmony>` in
  /// the score, in document order — matching the order Verovio emits `harm`
  /// groups in the SVG. Empty when there's no harmony (chords toggled off
  /// upstream, or a piece with no chord data).
  static List<String> _computeHarmLabels(String xml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } catch (_) {
      return const [];
    }
    final harmonies = doc.findAllElements('harmony').toList();
    if (harmonies.isEmpty) return const [];
    final keyEl = doc.findAllElements('key').firstOrNull;
    final fifths =
        int.tryParse(keyEl?.findElements('fifths').firstOrNull?.innerText ?? '') ?? 0;
    final mode = MusicXmlParser.parseKeyMode(
        keyEl?.findElements('mode').firstOrNull?.innerText);
    return [
      for (final h in harmonies)
        _harmLabel(MusicXmlParser.parseHarmonyLabel(h), fifths, mode),
    ];
  }

  static String _harmLabel(String? name, int fifths, KeyMode mode) {
    if (name == null) return '';
    final deg = ChordAnalysis.romanNumeral(
        keyFifths: fifths, keyMode: mode, chordName: name);
    return deg == null ? name : '$deg ($name)'; // degree-primary
  }

  /// Rewrites the visible text of each rendered `harm` group (in document order)
  /// to the corresponding [labels] entry. Verovio spaced/positioned the original
  /// chord symbol; we only change the glyph text (like [_swapTabFingerings] for
  /// tab frets). An empty label leaves the group untouched.
  static String _swapHarmLabels(String svg, List<String> labels) {
    final out = StringBuffer();
    var last = 0, search = 0, idx = 0;
    while (idx < labels.length) {
      final ci = svg.indexOf('class="harm"', search);
      if (ci < 0) break;
      final open = svg.lastIndexOf('<g', ci);
      final close = open < 0 ? -1 : _matchCloseG(svg, open);
      if (open < 0 || close < 0) {
        search = ci + 12;
        continue;
      }
      final label = labels[idx++];
      if (label.isEmpty) {
        search = close;
        continue;
      }
      out.write(svg.substring(last, open));
      out.write(_replaceFirstTextContent(svg.substring(open, close), label));
      last = close;
      search = close;
    }
    out.write(svg.substring(last));
    return out.toString();
  }

  /// Replaces the text of the first `<tspan>` (or bare `<text>`) inside [group]
  /// with [label], preserving all element attributes (position/anchor/font).
  static String _replaceFirstTextContent(String group, String label) {
    final esc = label
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    for (final re in [
      RegExp(r'(<tspan\b[^>]*>)([^<]*)(</tspan>)', dotAll: true),
      RegExp(r'(<text\b[^>]*>)([^<]*)(</text>)', dotAll: true),
    ]) {
      final m = re.firstMatch(group);
      if (m != null) {
        return group.replaceRange(m.start, m.end, '${m.group(1)}$esc${m.group(3)}');
      }
    }
    return group;
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
    return out;
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

  /// Per measure index → its system-line index.
  final List<int> measureLine;

  /// One tiled vertical band per system line (viewBox coords); adjacent bands
  /// touch with zero gap/overlap. Index with [measureLine].
  final List<({double top, double bottom})> lineBands;

  final int renderMs;

  const EngravedScore({
    required this.viewBox,
    required this.svg,
    required this.bboxById,
    required this.measures,
    required this.notes,
    required this.measureLine,
    required this.lineBands,
    required this.renderMs,
  });

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

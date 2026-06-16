import 'dart:convert';
import 'dart:ui' show Rect, Size, Offset;

import 'package:flutter/foundation.dart';
import 'package:verovio_flutter/verovio_flutter.dart';

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

  static String _keyFor(String xml, double widthPx, double scale) =>
      '${xml.hashCode}|${_bucketOf(widthPx)}|${scale.toStringAsFixed(1)}';

  /// Engrave [musicXml] targeting [widthPx] logical pixels of render width.
  ///
  /// Returns an [EngravedScore]: the jovial-ready SVG, the page viewBox, and
  /// index-based geometric anchors for measures and notes. The score is
  /// domain-free — callers map a measure's document [index] to their model
  /// measure number (the same index↔number contract the OSMD bridge used).
  Future<EngravedScore> engrave(
    String musicXml, {
    required double widthPx,
    double scale = 40,
  }) {
    final key = _keyFor(musicXml, widthPx, scale);
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
      final score = await _engraveNow(musicXml, widthPx: widthPx, scale: scale);
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
  }) async {
    final svc = await _ensureService();
    final sw = Stopwatch()..start();

    // pageWidth is in MEI units; rendered viewBox px ≈ pageWidth * scale / 100.
    final pageWidthUnits = (widthPx * 100 / scale).round();
    final options = <String, Object>{
      'scale': scale.round(),
      'pageWidth': pageWidthUnits,
      'adjustPageHeight': true, // one tall page; systems wrap to width
      'breaks': 'auto',
      'footer': 'none',
      'header': 'none',
      'mnumInterval': 4, // measure numbers every 4 bars
      'svgViewBox': true, // root viewBox so the renderer can scale
    };
    await svc.setOptionsJson(jsonEncode(options));
    await svc.loadData(musicXml);

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

    // Assign each note/rest to the measure whose bbox contains its center,
    // then rank within the measure by x to get our positional noteIndex
    // (which counts rests). This is robust to qstamp/tick alignment quirks.
    final noteHits = hitMap.byType
        .where((h) => h.type == 'note' || h.type == 'rest')
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

    return EngravedScore(
      viewBox: hitMap.viewBox,
      svg: flattenForRenderer(svg),
      bboxById: bboxById,
      measures: measures,
      notes: notes,
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

  final int renderMs;

  const EngravedScore({
    required this.viewBox,
    required this.svg,
    required this.bboxById,
    required this.measures,
    required this.notes,
    required this.renderMs,
  });

  MeasureAnchor? measureAt(int index) =>
      (index < 0 || index >= measures.length) ? null : measures[index];

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

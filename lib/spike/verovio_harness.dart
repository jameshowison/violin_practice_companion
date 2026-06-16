// THROWAWAY spike harness (branch: spike/verovio-rendering). NOT for merge.
//
// Proves out on-device Verovio rendering vs. the OSMD WebView:
//   - fidelity: Verovio SVG rendered through flutter_svg (BoxFit, no WebView)
//   - reflow:   re-engrave at two page widths via setOptionsJson(pageWidth)
//   - bboxes:   renderPageWithHitMap -> tap a note -> native colored overlay
//   - cursor:   renderToTimemap + getElementsAtTime dumped to logs
//
// Wired in as the app home by lib/main.dart ONLY on this spike branch.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:verovio_flutter/verovio_flutter.dart';

class VerovioHarnessApp extends StatelessWidget {
  const VerovioHarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Verovio Spike',
      theme: ThemeData(useMaterial3: true),
      home: const VerovioHarnessPage(),
    );
  }
}

/// Representative fixtures spanning simple -> import-path -> ornamented.
// Known-good SVG: a black stroked line, a red filled circle, and a <use> of a
// <defs> path — mirrors the Verovio features under test.
const _kProbeSvg = '''
<svg viewBox="0 0 200 60" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
  <defs><g id="blob"><path d="M0 0 h20 v12 h-20 z"/></g></defs>
  <line x1="0" y1="10" x2="200" y2="10" stroke="#000000" stroke-width="2"/>
  <circle cx="30" cy="35" r="12" fill="#d00"/>
  <use xlink:href="#blob" transform="translate(120,30)" fill="#06c"/>
</svg>''';

const _fixtures = <String>[
  'assets/fixtures/lightly_row_musescore.xml',
  'assets/fixtures/happy_farmer_musescore.xml',
  'assets/fixtures/gossec_gavotte.xml',
  'assets/fixtures/abc_17_gavotte.xml',
  'assets/fixtures/homr_17_gavotte.xml',
];

class VerovioHarnessPage extends StatefulWidget {
  const VerovioHarnessPage({super.key});

  @override
  State<VerovioHarnessPage> createState() => _VerovioHarnessPageState();
}

class _VerovioHarnessPageState extends State<VerovioHarnessPage> {
  VerovioAsyncService? _svc;
  String _fixture = _fixtures.first;
  final int _scale = 40;
  // Two width buckets to probe reflow: phone-portrait vs tablet-landscape.
  final _widthBuckets = const {'phone': 720, 'tablet': 1600};
  String _bucket = 'phone';

  String? _svg; // sanitized-for-flutter_svg (legacy probe path)
  ScalableImage? _si; // jovial_svg parse of the (style-preserving) flatten
  String _renderer = 'jovial'; // 'jovial' | 'flutter_svg'
  bool _showBboxes = true; // Phase 0: draw every note bbox to verify alignment
  PageHitMap? _hitMap;
  ElementHit? _selected; // tapped note -> native overlay
  String _status = 'init…';
  int _lastRenderMs = 0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final resourcePath =
          await VerovioResourceManager.ensureVerovioAssetsReady();
      _svc = await VerovioAsyncService.spawn(resourcePath: resourcePath);
      final v = await _svc!.getVersion();
      debugPrint('[spike] Verovio version: $v');
      await _render();
    } catch (e, st) {
      debugPrint('[spike] boot error: $e\n$st');
      setState(() => _status = 'boot error: $e');
    }
  }

  Future<void> _render() async {
    final svc = _svc;
    if (svc == null) return;
    setState(() {
      _status = 'loading $_fixture…';
      _selected = null;
    });
    final sw = Stopwatch()..start();
    try {
      final xml = await rootBundle.loadString(_fixture);

      // pageWidth is in MEI units; viewBox px ≈ pageWidth * scale / 100.
      // Pick pageWidth so the engraving targets the chosen device bucket.
      final pageWidthUnits = (_widthBuckets[_bucket]! * 100 / _scale).round();
      final options = <String, Object>{
        'scale': _scale,
        'pageWidth': pageWidthUnits,
        'adjustPageHeight': true, // one tall page -> wraps systems to width
        'breaks': 'auto',
        'footer': 'none',
        'header': 'none',
        'mnumInterval': 4,
        'svgViewBox': true, // add root viewBox so flutter_svg can scale
      };
      await svc.setOptionsJson(jsonEncode(options));
      await svc.loadData(xml);

      final pages = await svc.pageCount;
      final res = await svc.renderPageWithHitMap(1);
      sw.stop();

      // --- SVG structure diagnostics (fidelity root-cause) ---
      final s = res.svg;
      int countOf(String tag) => RegExp('<$tag[ />]').allMatches(s).length;
      debugPrint('[spike] SVG len=${s.length} '
          'style=${countOf('style')} class="=${RegExp('class=').allMatches(s).length} '
          'path=${countOf('path')} use=${countOf('use')} '
          'symbol=${countOf('symbol')} text=${countOf('text')} '
          'g=${countOf('g')} rect=${countOf('rect')}');
      // Transform skeleton: every <svg>/<g> opening tag up to the first <use>,
      // to expose the nested-transform structure flutter_svg must honor.
      final headEnd = s.indexOf('<use');
      final head = headEnd > 0 ? s.substring(0, headEnd) : s;
      final tags = RegExp(r'<(svg|g)\b[^>]*>')
          .allMatches(head)
          .map((m) => m.group(0))
          .toList();
      debugPrint('[spike] skeleton (${tags.length} group tags to first <use>):');
      for (final t in tags) {
        debugPrint('[spike]   $t');
      }
      final useM = RegExp(r'<use[^>]*>').firstMatch(s);
      debugPrint('[spike] first <use>: ${useM?.group(0)}');
      // The <defs><g id="..."> the first <use> points at:
      final href = RegExp(r'href="#([^"]+)"').firstMatch(useM?.group(0) ?? '');
      if (href != null) {
        final defM = RegExp('<g id="${href.group(1)}"[\\s\\S]*?</g>').firstMatch(s);
        final d = defM?.group(0) ?? '(not found)';
        debugPrint('[spike] glyph def: ${d.substring(0, d.length < 220 ? d.length : 220)}');
      }

      // --- cursor-path evidence (step 3/4): dump timemap + a time query ---
      final timemap = await svc.renderToTimemap();
      final tmList = (jsonDecode(timemap) as List);
      debugPrint('[spike] timemap entries: ${tmList.length}; '
          'first=${tmList.isEmpty ? "-" : tmList.first}');
      final atOneSec = await svc.getElementsAtTime(1000);
      debugPrint('[spike] elementsAtTime(1000ms)=$atOneSec');
      // ID-mapping evidence: inspect the first note element's attributes.
      final notes = res.hitMap.byType.where((h) => h.type == 'note');
      if (notes.isNotEmpty) {
        final firstNote = notes.first;
        final attr = await svc.getElementAttr(firstNote.id);
        final times = await svc.getTimesForElement(firstNote.id);
        debugPrint('[spike] firstNote id=${firstNote.id} '
            'attr=$attr times=$times');
      }

      // jovial_svg path: it parses <style>/currentColor, so we only need to
      // flatten Verovio's nested <svg class="definition-scale"> (jovial throws
      // on a second <svg> tag) — keep the CSS block intact.
      ScalableImage? si;
      try {
        final flat = _flattenNestedSvgForJovial(res.svg);
        si = ScalableImage.fromSvgString(
          flat,
          currentColor: Colors.black, // resolves stroke:currentColor
          warnF: (w) => debugPrint('[spike][jovial] $w'),
        );
      } catch (e, st) {
        debugPrint('[spike][jovial] parse error: $e\n$st');
      }

      setState(() {
        _svg = _sanitizeForFlutterSvg(res.svg);
        _si = si;
        _hitMap = res.hitMap;
        _lastRenderMs = sw.elapsedMilliseconds;
        _status = 'OK · pages=$pages · viewBox=${res.hitMap.viewBox.width.toStringAsFixed(0)}'
            '×${res.hitMap.viewBox.height.toStringAsFixed(0)} · '
            'hits=${res.hitMap.byType.length} · ${_lastRenderMs}ms';
      });
    } catch (e, st) {
      sw.stop();
      debugPrint('[spike] render error: $e\n$st');
      setState(() => _status = 'render error: $e');
    }
  }

  /// jovial_svg shim: jovial parses <style> + currentColor (the two things
  /// flutter_svg drops), so the ONLY normalization it needs is collapsing
  /// Verovio's nested <svg class="definition-scale" viewBox="0 0 18000 …"> into
  /// a <g transform="scale(...)"> — jovial throws "Second <svg> tag in file".
  /// The CSS <style> block is preserved verbatim.
  String _flattenNestedSvgForJovial(String svg) {
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
      // First </svg> closes the (now-removed) inner svg; outer </svg> stays.
      out = out.replaceFirst('</svg>', '</g>');
    }
    return out;
  }

  /// Probe shim: flutter_svg drops Verovio's <style> block (which sets
  /// stroke:currentColor on all path/rect/polygon). Strip it and inline a
  /// black stroke on stroked primitives. Reveals whether <use> glyphs (the
  /// other half of the render) resolve at all.
  String _sanitizeForFlutterSvg(String svg) {
    var out = svg;

    // (1) Flatten Verovio's nested <svg class="definition-scale" viewBox=...>
    // into a <g transform="scale(sx,sy)"> — flutter_svg ignores nested-svg
    // viewBox scaling, so without this everything renders off-canvas.
    final outerVb = RegExp(r'<svg[^>]*viewBox="0 0 ([\d.]+) ([\d.]+)"')
        .firstMatch(out);
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
          innerOpen.group(0)!, '<g transform="scale($sx, $sy)" color="black">');
      // The inner </svg> is the first </svg> in the doc (content has no nested
      // svg); the remaining final </svg> closes the outer.
      out = out.replaceFirst('</svg>', '</g>');
    }

    // (2) Drop the <style> block and inline a black stroke on stroked prims
    // (Verovio sets stroke only via CSS stroke:currentColor).
    out = out.replaceAll(RegExp(r'<style[\s\S]*?</style>'), '');
    for (final tag in ['path', 'rect', 'polygon', 'polyline', 'ellipse']) {
      out = out.replaceAllMapped(
        RegExp('<$tag '),
        (_) => '<$tag stroke="#000000" ',
      );
    }
    return out;
  }

  void _onTapSvg(Offset local, Size renderedSize) {
    final hm = _hitMap;
    if (hm == null) return;
    // Map widget-local px -> SVG viewBox coords (uniform fitWidth scale).
    final s = renderedSize.width / hm.viewBox.width;
    final vbPoint = Offset(local.dx / s, local.dy / s);
    final allHits = hitTestPointAll(hm, vbPoint);
    final noteHits = hitTestPointAll(hm, vbPoint, types: {'note'});
    debugPrint('[spike] tap vb=$vbPoint -> ${allHits.map((h) => h.type).toList()}');
    setState(() => _selected = noteHits.isEmpty ? null : noteHits.first);
  }

  @override
  void dispose() {
    _svc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verovio spike'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(_status, style: const TextStyle(fontSize: 12)),
          ),
        ),
      ),
      body: Column(
        children: [
          _controls(),
          const Divider(height: 1),
          Expanded(child: _stage()),
        ],
      ),
    );
  }

  Widget _controls() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          DropdownButton<String>(
            value: _fixture,
            items: [
              for (final f in _fixtures)
                DropdownMenuItem(
                  value: f,
                  child: Text(f.split('/').last, key: ValueKey('fx_$f')),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _fixture = v);
              _render();
            },
          ),
          const SizedBox(width: 12),
          const Text('width:'),
          for (final b in _widthBuckets.keys)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                key: ValueKey('bucket_$b'),
                label: Text(b),
                selected: _bucket == b,
                onSelected: (_) {
                  setState(() => _bucket = b);
                  _render();
                },
              ),
            ),
          const SizedBox(width: 12),
          const Text('renderer:'),
          for (final r in const ['jovial', 'flutter_svg'])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                key: ValueKey('renderer_$r'),
                label: Text(r),
                selected: _renderer == r,
                onSelected: (_) => setState(() => _renderer = r),
              ),
            ),
          const SizedBox(width: 8),
          FilterChip(
            key: const ValueKey('toggle_bbox'),
            label: const Text('bboxes'),
            selected: _showBboxes,
            onSelected: (v) => setState(() => _showBboxes = v),
          ),
          const SizedBox(width: 12),
          IconButton(
            key: const ValueKey('rerender'),
            icon: const Icon(Icons.refresh),
            onPressed: _render,
          ),
        ],
      ),
    );
  }

  Widget _stage() {
    final svg = _svg;
    final hm = _hitMap;
    if (svg == null || hm == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final renderW = constraints.maxWidth;
        final renderH = renderW * hm.viewBox.height / hm.viewBox.width;
        final renderedSize = Size(renderW, renderH);
        final scale = renderW / hm.viewBox.width;
        final useJovial = _renderer == 'jovial';
        return SingleChildScrollView(
          child: GestureDetector(
            onTapDown: (d) => _onTapSvg(d.localPosition, renderedSize),
            child: SizedBox(
              width: renderW,
              height: renderH,
              child: Stack(
                children: [
                  if (useJovial)
                    if (_si != null)
                      SizedBox(
                        width: renderW,
                        height: renderH,
                        child: ScalableImageWidget(
                          si: _si!,
                          fit: BoxFit.fitWidth,
                        ),
                      )
                    else
                      const Center(child: Text('jovial parse failed'))
                  else
                    SvgPicture.string(
                      svg,
                      width: renderW,
                      height: renderH,
                      fit: BoxFit.fitWidth, // uniform scale — never BoxFit.fill
                    ),
                  // Phase 0 alignment proof: outline EVERY note bbox. If these
                  // boxes hug the noteheads, hitMap coords share the page
                  // viewBox space the overlays/cursor will use.
                  if (_showBboxes)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _BboxDebugPainter(
                            hits: hm.byType
                                .where((h) => h.type == 'note')
                                .toList(),
                            scale: scale,
                          ),
                        ),
                      ),
                    ),
                  if (_selected != null)
                    _SelectionOverlay(hit: _selected!, scale: scale),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Phase 0 debug: draw an outline at every note's hitMap bbox so we can
/// eyeball whether bbox coords align with the rendered glyphs.
class _BboxDebugPainter extends CustomPainter {
  _BboxDebugPainter({required this.hits, required this.scale});
  final List<ElementHit> hits;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0xCCFF00AA);
    for (final h in hits) {
      final r = h.bbox;
      canvas.drawRect(
        Rect.fromLTWH(
            r.left * scale, r.top * scale, r.width * scale, r.height * scale),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_BboxDebugPainter old) =>
      old.hits != hits || old.scale != scale;
}

/// Native colored highlight over a tapped note — the "full control over
/// colored highlighting" the WebView made awkward.
class _SelectionOverlay extends StatelessWidget {
  const _SelectionOverlay({required this.hit, required this.scale});
  final ElementHit hit;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final r = hit.bbox;
    return Positioned(
      left: r.left * scale - 4,
      top: r.top * scale - 4,
      width: r.width * scale + 8,
      height: r.height * scale + 8,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.35),
            border: Border.all(color: Colors.deepOrange, width: 2),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}

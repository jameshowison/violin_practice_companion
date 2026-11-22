// The safety net for moving the engraving layer into score_view
// (docs/libraries-migration.md, step 4).
//
// Nothing headless runs a native engrave, so this pins what does run without
// one: every static VerovioEngraver pass over the recorded Verovio SVGs
// (test/fixtures/verovio_*.svg), the EngravedScore JSON round trip and its
// derived getters, and the staff_zoom, section_line_planner,
// section_engraving, print_paginator and system-break outputs over a fixed
// grid of inputs. A digest of each result is compared with
// test/fixtures/engraving_snapshot.json. A seam, a move or an import rewrite
// must leave every digest identical; a real behaviour change refreshes them:
//
//   UPDATE_SNAPSHOT=1 flutter test test/engraving_snapshot_test.dart
//
// To see WHAT changed, dump the full text before and after and diff the dirs:
//
//   SNAPSHOT_DUMP=/tmp/snap_before flutter test test/engraving_snapshot_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:score_view/score_view.dart';

import 'support/bundled_scores.dart';

const _goldenPath = 'test/fixtures/engraving_snapshot.json';

const _svgFixtures = [
  'test/fixtures/verovio_bbox.svg',
  'test/fixtures/verovio_ending.svg',
  'test/fixtures/verovio_harm.svg',
  'test/fixtures/verovio_ojc_reserved.svg',
  'test/fixtures/verovio_tab_harm.svg',
];

/// 64-bit FNV-1a over the UTF-8 bytes, as hex (as migration_snapshot_test).
String _digest(String s) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h *= 0x100000001b3; // wraps at 64 bits on the VM
  }
  String hex32(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return hex32(h >>> 32) + hex32(h);
}

/// Full precision, unlike Rect.toString.
String _r(Rect? r) =>
    r == null ? 'null' : '[${r.left},${r.top},${r.right},${r.bottom}]';

String _guard(Object? Function() f) {
  try {
    return '${f()}';
  } catch (e) {
    return 'THREW ${e.runtimeType}: $e';
  }
}

int _measureCount(String xml) {
  final part = RegExp(r'<part\b[^>]*>(.*?)</part>', dotAll: true)
      .firstMatch(xml)
      ?.group(1);
  return part == null ? 0 : RegExp(r'<measure\b').allMatches(part).length;
}

/// Deterministic, uneven natural widths in MEI units.
List<double> _widths(int n, int seed) =>
    [for (var i = 0; i < n; i++) 180.0 + ((i * 37 + seed * 11) % 170)];

Map<String, String> _svgStages(String name, String svg) {
  final out = <String, String>{};
  void add(String k, Object? Function() f) => out['$name $k'] = _guard(f);
  add('stripAnnotationGlyphs', () => VerovioEngraver.stripAnnotationGlyphs(svg));
  add('stripEndings', () => VerovioEngraver.stripEndings(svg));
  add('stripMeasureNumbers', () => VerovioEngraver.stripMeasureNumbers(svg));
  add('clefFirstSystemOnly', () => VerovioEngraver.clefFirstSystemOnly(svg));
  add('flattenForRenderer', () => VerovioEngraver.flattenForRenderer(svg));
  add('withoutLyrics', () => VerovioEngraver.withoutLyrics(svg));
  add('resolveTextFont', () => VerovioEngraver.resolveTextFont(svg));
  add('stripBoundingBoxes', () => VerovioEngraver.stripBoundingBoxes(svg));
  add('systemInkBoxes', () => VerovioEngraver.systemInkBoxes(svg));
  add('measureStaffLines', () => VerovioEngraver.measureStaffLines(svg));
  final noteIds = [
    for (final m in RegExp(r'<g id="([^"]+)" class="note"').allMatches(svg))
      m.group(1)!,
  ];
  const fills = ['#e53935', '#1e88e5', '#43a047', '#fdd835'];
  add('colourNoteheads', () => VerovioEngraver.colourNoteheads(svg, {
        for (var i = 0; i < noteIds.length; i += 3)
          noteIds[i]: fills[(i ~/ 3) % fills.length],
      }));
  add('colourNoteheads.none', () => VerovioEngraver.colourNoteheads(svg, {}));
  final endingIds = [
    for (final m in RegExp(r'<g id="([^"]+)" class="ending\b').allMatches(svg))
      m.group(1)!,
  ];
  add('endings', () => [
        for (final id in endingIds)
          '$id:${VerovioEngraver.endingLabelOf(svg, id)}:'
              '${VerovioEngraver.endingClosedOf(svg, id)}',
      ].join(';'));
  // The full chain the staff view applies, in its usual order.
  add('chain', () => VerovioEngraver.flattenForRenderer(
      VerovioEngraver.resolveTextFont(VerovioEngraver.stripBoundingBoxes(
          VerovioEngraver.stripEndings(VerovioEngraver.stripMeasureNumbers(
              VerovioEngraver.stripAnnotationGlyphs(svg)))))));
  return out;
}

EngravedScore _sampleScore() {
  const r = Rect.fromLTRB(1.5, 2, 30.25, 40);
  const s = Rect.fromLTRB(40, 210, 70.5, 260);
  return EngravedScore(
    viewBox: const Size(800, 1200.5),
    svg: '<svg viewBox="0 0 800 1200.5"><g/></svg>',
    bboxById: const {'n1': r, 'n2': s},
    measures: const [
      MeasureAnchor(index: 0, id: 'm1', rect: r),
      MeasureAnchor(index: 1, id: 'm2', rect: r),
      MeasureAnchor(index: 2, id: 'm3', rect: s),
    ],
    notes: const [
      NoteAnchor(
          id: 'n1', measureIndex: 0, noteIndex: 0, isRest: false, rect: r,
          beatPosition: 0.25),
      NoteAnchor(id: 'r1', measureIndex: 0, noteIndex: 1, isRest: true, rect: r),
      NoteAnchor(
          id: 'n2', measureIndex: 2, noteIndex: 0, isRest: false, rect: s,
          beatPosition: 0),
    ],
    meterSigs: const [r],
    keyAccids: const [r, s],
    measureLine: const [0, 0, 1],
    lineBands: const [(top: 0, bottom: 100), (top: 100, bottom: 300.5)],
    lineContent: const [(top: 5, bottom: 95), (top: 205, bottom: 280)],
    fingAnchors: const [(line: 0, x: 12, y: -3.5), (line: 1, x: 50, y: 190)],
    harmAnchors: const [(line: 1, x: 40.5, y: 100)],
    endings: const [
      EngravedEnding(line: 1, rect: s, label: '1', closedRight: true),
    ],
    staffLines: const [
      (top: 20, left: 0, right: 30),
      (top: 20, left: 30, right: 60),
      (top: 220, left: 0, right: 70),
    ],
    pageWidthUnits: 2000,
    renderMs: 42,
  );
}

Map<String, String> _scoreStages() {
  final out = <String, String>{};
  final score = _sampleScore();
  final j = jsonEncode(score.toJson());
  out['score.toJson'] = j;
  final back = EngravedScore.fromJson(jsonDecode(j) as Map<String, dynamic>);
  out['score.roundTrip'] = jsonEncode(back.toJson());
  for (final s in [score, back]) {
    final tag = identical(s, score) ? 'orig' : 'back';
    out['score.$tag.getters'] = [
      s.lineCount, s.engravedScale, s.staffHeightViewBox, s.staffSpaceViewBox,
      s.systemHeightViewBox, s.contentHeightViewBox,
      for (var l = -1; l < 3; l++) ...[
        s.fingRegister(l), s.harmRegister(l), s.chordRegister(l),
        _r(s.meterSigOnLine(l)), s.keyAccidsOnLine(l).map(_r).join(','),
      ],
      for (var m = -1; m < 4; m++) ...[
        s.staffLineAt(m), s.measureAt(m)?.id, s.lineOfMeasure(m),
        s.bandForMeasure(m),
        for (var n = 0; n < 3; n++) s.noteAt(m, n)?.id,
      ],
    ].join('|');
  }
  final measures = score.measures;
  out['measureIndexFor'] = [
    for (final b in const [
      Rect.fromLTRB(2, 3, 10, 20),
      Rect.fromLTRB(41, 211, 50, 230),
      Rect.fromLTRB(500, 500, 510, 510),
      Rect.fromLTRB(25, 30, 45, 220),
    ])
      VerovioEngraver.measureIndexFor(b, measures),
  ].join(',');
  out['clipToNextMeasure'] = [
    _r(VerovioEngraver.clipToNextMeasure(
        const Rect.fromLTRB(0, 0, 50, 10), const Rect.fromLTRB(40, 0, 80, 10))),
    _r(VerovioEngraver.clipToNextMeasure(const Rect.fromLTRB(0, 0, 50, 10), null)),
    _r(VerovioEngraver.clipToNextMeasure(
        const Rect.fromLTRB(0, 0, 50, 10), const Rect.fromLTRB(0, 100, 80, 110))),
  ].join(',');
  out['isGraceAttr'] = [
    for (final a in const ['{}', '{"grace":"unacc"}', '{"grace":"acc"}', 'nope'])
      _guard(() => VerovioEngraver.isGraceAttr(a)),
  ].join(',');
  return out;
}

Map<String, String> _staffZoomStages() {
  final out = <String, String>{};
  const sides = [320.0, 375.0, 402.0, 600.0, 834.0, 1024.0];
  const widths = [358.0, 706.0, 790.0, 1180.0];
  const upms = [250.0, 600.0, 1200.0];
  out['minStaffScaleFor'] = [for (final s in sides) minStaffScaleFor(s)].join(',');
  out['staffScaleForSize'] = [
    for (final z in StaffSize.values)
      for (final s in sides) '${z.name}:${staffScaleForSize(z, s)}',
  ].join(',');
  out['measuresPerLineForSize'] = [
    for (final z in StaffSize.values)
      for (final w in widths)
        for (final u in upms)
          measuresPerLineForSize(
              size: z, widthPx: w, unitsPerMeasure: u, shortestSidePx: 375),
  ].join(',');
  out['spacingLinearForSize'] = [
    for (final z in StaffSize.values)
      for (final a in [false, true]) spacingLinearForSize(z, annotated: a),
  ].join(',');
  out['fitSpacingLinear'] = [
    for (final h in [300.0, 600.0, 900.0, 1500.0])
      for (final b in [500.0, 800.0])
        fitSpacingLinear(
            predictedHeightPx: h, budgetPx: b,
            widthAtDefault: 1000, widthAtMin: 800),
  ].join(',');
  out['naturalWidthAtSpacing'] = [
    for (final s in [0.1, 0.15, 0.2, 0.25, 0.3, 0.4])
      naturalWidthAtSpacing(s, widthAtDefault: 1000, widthAtMin: 800),
  ].join(',');
  out['verovioSpacingSystemFor'] = [
    for (var i = -2; i <= 34; i++) verovioSpacingSystemFor(i * 0.05),
  ].join(',');
  out['annotationReserveFor'] = [
    for (final a in [0.0, 2.0, 5.0, 12.0])
      for (final f in [0.0, 3.0, 8.0])
        for (final w in [1.0, 4.0, 9.0])
          annotationReserveFor(
              interSystemRoomSpaces: a, firstSystemRoomSpaces: f, wantSpaces: w),
  ].join(',');
  out['annotationFontSizeFor'] =
      [for (final s in [0.0, 4.0, 7.5, 12.0, 20.0]) annotationFontSizeFor(s)].join(',');
  out['annotationStackFor'] = [
    for (final b in [10.0, 30.0, 60.0])
      for (final s in [5.0, 9.0])
        for (final c in [false, true])
          for (final f in [false, true])
            annotationStackFor(
                budgetPx: b, staffSpacePx: s, labelShare: 0.6, typeShare: 0.8,
                withChordBar: c, withFingeringRow: f),
  ].join(',');
  out['annotationFontSizeIn'] = [
    for (final s in [4.0, 9.0])
      for (final l in [6.0, 14.0, 30.0])
        annotationFontSizeIn(staffSpacePx: s, laneHeightPx: l),
  ].join(',');
  out['sectionMarkerScaleFor'] =
      [for (final n in [null, 1, 2, 3, 4, 5, 6, 8, 12]) sectionMarkerScaleFor(n)].join(',');
  final rects = [
    for (var i = 0; i < 11; i++)
      Rect.fromLTWH((i % 4) * 100.0, (i ~/ 4) * 150.0 + (i % 2) * 3, 95, 80 + i % 3),
  ];
  final (lines, bands) = systemLinesOf(rects);
  out['systemLinesOf'] = '$lines $bands';
  out['lineContentOf'] = '${lineContentOf(rects, lines)}';
  out['measuresPerLineOf'] = [
    for (final ml in [lines, <int>[], [0], [0, 0, 0, 1, 1, 1, 2], [0, 1, 1, 2, 2, 2, 3]])
      measuresPerLineOf(ml),
  ].join(',');
  out['unitsPerMeasureFrom'] = [
    for (final p in [1000, 2000, 4500])
      for (final n in [1, 3, 4, 8]) unitsPerMeasureFrom(pageWidthUnits: p, measuresPerLine: n),
  ].join(',');
  out['tighterUnitsPerMeasure'] = [
    for (final c in [300.0, 600.0])
      for (final o in [200.0, 600.0, 900.0]) tighterUnitsPerMeasure(c, o),
  ].join(',');
  out['scaleFor'] = [
    for (final w in widths)
      for (final u in upms)
        for (final n in [1, 3, 5, 8]) scaleFor(widthPx: w, unitsPerMeasure: u, n: n),
  ].join(',');
  out['predictedHeightPx'] = [
    for (final w in widths)
      for (final n in [2, 4, 6])
        predictedHeightPx(
            widthPx: w, unitsPerMeasure: 600, systemHeightPx: 120,
            measureCount: 32, n: n),
  ].join(',');
  out['maxMeasuresPerLineFor'] = [
    for (final w in widths)
      for (final u in upms)
        for (final s in [375.0, 834.0])
          maxMeasuresPerLineFor(widthPx: w, unitsPerMeasure: u, shortestSidePx: s),
  ].join(',');
  out['autoMeasuresPerLine'] = [
    for (final w in widths)
      for (final h in [500.0, 900.0])
        for (final mc in [8, 24, 64])
          autoMeasuresPerLine(
              widthPx: w, viewportHeightPx: h, shortestSidePx: 375,
              unitsPerMeasure: 600, systemHeightPx: 140, measureCount: mc),
  ].join(',');
  out['measuresPerLineForWidth'] = [
    for (final w in [200.0, 358.0, 500.0, 706.0, 790.0, 1180.0, 2000.0])
      measuresPerLineForWidth(w),
  ].join(',');
  out['constants'] = [
    staffScaleProbe, staffScaleMin, staffScaleMax, measuresPerLineMin,
    measuresPerLineMax, staffAutoFillFraction, staffFitSlack,
    verovioSpacingSystemDefault, verovioPageMarginTopDefault, verovioSideMargin,
    verovioPageMarginTopMax, verovioSpacingSystemMax, verovioPageHeightMax,
    sectionNaturalLineWidthPx, sectionPageMarginUnits, sectionLineStartUnits,
  ].join(',');
  return out;
}

Map<String, String> _plannerStages() {
  final out = <String, String>{};
  for (final n in [3, 9, 17, 32]) {
    final w = _widths(n, n);
    final starts = [0, for (var i = 4; i < n; i += 8) i];
    final labels = {for (var k = 0; k < starts.length; k++) starts[k]: k.isEven ? 'A' : 'B'};
    for (final maxUnits in [600.0, 1200.0, 3000.0]) {
      for (final lines in [null, 1, 2, 3]) {
        for (final balance in [true, false]) {
          out['plan n$n max$maxUnits lines$lines bal$balance'] = _guard(() =>
              planSectionLines(
                  widths: w, segmentStarts: starts, maxLineUnits: maxUnits,
                  lines: lines, segmentLabels: labels, balanceDensity: balance));
        }
      }
    }
    for (final k in [1, 2, 3, 5]) {
      out['balancedLines n$n k$k'] = _guard(() => balancedLines(w, k));
    }
  }
  final segs = [_widths(4, 1), _widths(8, 2), _widths(8, 3), _widths(5, 4)];
  final count = [1, 1, 2, 1];
  evenDensity(segs, count, const {0: 'A', 1: 'B', 2: 'A', 3: 'C'});
  out['evenDensity'] = '$count';
  out['justifyLastSectionLine'] = [
    for (final lu in [
      <double>[], [900.0], [900.0, 400.0], [900.0, 950.0, 200.0],
      [800.0, 850.0, 700.0], [900.0, 0.0],
    ])
      for (final p in [0.0, 1000.0])
        justifyLastSectionLine(lineUnits: lu, pageUnits: p),
  ].join(',');
  out['paginateLines'] = [
    for (final first in [300.0, 600.0])
      for (final page in [500.0, 900.0])
        for (final starts in [<int>{}, {3, 7}, {1, 2, 5, 9}])
          paginateLines(
            lines: [
              for (var i = 0; i < 12; i++)
                (top: i * 110.0, bottom: i * 110.0 + 90 + (i == 6 ? 600 : 0)),
            ],
            sectionStarts: starts,
            firstPageHeight: first,
            pageHeight: page,
          ),
  ].join(';');
  return out;
}

Map<String, String> _xmlStages(String name, String xml) {
  final out = <String, String>{};
  void add(String k, Object? Function() f) => out['$name $k'] = _guard(f);
  final n = _measureCount(xml);
  final numbers = [
    for (final m in RegExp(r'<measure\b[^>]*number="(\d+)"').allMatches(xml))
      int.parse(m.group(1)!),
  ];
  final sections = [
    for (var i = 0; i < numbers.length; i += 4)
      Section(label: i ~/ 4 % 2 == 0 ? 'A' : 'B', startMeasure: numbers[i]),
  ];
  add('stripPartLabels', () => VerovioEngraver.stripPartLabels(xml));
  add('scoreReservesAnnotationRoom', () => scoreReservesAnnotationRoom(xml));
  add('systemStartPositions.raw', () => systemStartPositions(xml));
  final positions = {for (var i = 3; i < n; i += 3) i};
  add('insertBreaksAtPositions', () => insertBreaksAtPositions(xml, positions));
  add('insertBreaksAtPositions.empty', () => insertBreaksAtPositions(xml, {}));
  add('systemStartPositions.broken',
      () => systemStartPositions(insertBreaksAtPositions(xml, positions)));
  for (final mpl in [null, 2, 4]) {
    add('insertSystemBreaks.$mpl',
        () => insertSystemBreaks(xml, measuresPerLine: mpl, sections: sections));
  }
  add('freezeSystemBreaks',
      () => freezeSystemBreaks(xml, {for (var i = 2; i < numbers.length; i += 3) numbers[i]}));
  add('hideFirstSystemPreamble', () => hideFirstSystemPreamble(xml));
  // The section layout over the xml broken before every section.
  final broken = _guard(() => insertSystemBreaks(xml, sections: sections));
  if (!broken.startsWith('THREW')) {
    final w = _widths(n, numbers.length);
    for (final width in [358.0, 790.0]) {
      for (final minScale in [24.0, 32.0]) {
        for (final lps in [null, 1, 2]) {
          add('solveSectionLayout w$width min$minScale lps$lps', () {
            final r = solveSectionLayout(
                musicXml: broken, naturalWidths: w, widthPx: width,
                minScale: minScale, linesPerSection: lps,
                sectionLabels: {0: 'A'});
            return '${_digest(r.xml)} ${r.scale} ${r.lines} ${r.maxLines} '
                '${r.breaks} ${r.widestUnits} ${r.minLastJustification}';
          });
        }
        add('sectionFitCandidates w$width min$minScale', () {
          final c = sectionFitCandidates(
              musicXml: broken, naturalWidths: w, widthPx: width,
              viewportHeightPx: 600, systemHeightPx: 130, minScale: minScale);
          String p(({String xml, double scale, int lines, int maxLines,
                  Set<int> breaks, double widestUnits,
                  double? minLastJustification})? r) =>
              r == null
                  ? 'null'
                  : '${_digest(r.xml)} ${r.scale} ${r.lines} ${r.maxLines} '
                      '${r.breaks} ${r.widestUnits} ${r.minLastJustification}';
          return '${p(c.fits)} / ${p(c.bigger)}';
        });
      }
    }
  }
  return out;
}

void main() {
  test('the engraving layer\'s outputs match the snapshot', () {
    final actual = <String, String>{};
    for (final path in _svgFixtures) {
      actual.addAll(_svgStages(path, File(path).readAsStringSync()));
    }
    actual.addAll(_scoreStages());
    actual.addAll(_staffZoomStages());
    actual.addAll(_plannerStages());
    for (final f in bundledScoreFiles()) {
      actual.addAll(_xmlStages(f.path, f.readAsStringSync()));
    }

    final dumpDir = Platform.environment['SNAPSHOT_DUMP'];
    if (dumpDir != null) {
      for (final e in actual.entries) {
        final out = File('$dumpDir/${e.key.replaceAll(RegExp(r'[/ ]'), '_')}.txt');
        out.parent.createSync(recursive: true);
        out.writeAsStringSync(e.value);
      }
    }
    final digests = {for (final e in actual.entries) e.key: _digest(e.value)};

    final golden = File(_goldenPath);
    if (Platform.environment['UPDATE_SNAPSHOT'] == '1' || !golden.existsSync()) {
      final sorted = Map.fromEntries(
          digests.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
      golden.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(sorted)}\n');
      return;
    }
    final expected =
        (json.decode(golden.readAsStringSync()) as Map).cast<String, String>();
    final changed = [
      for (final k in {...expected.keys, ...digests.keys})
        if (expected[k] != digests[k]) k,
    ]..sort();
    expect(changed, isEmpty,
        reason: '${changed.length} outputs changed; dump with '
            'SNAPSHOT_DUMP before and after to see how');
  });
}

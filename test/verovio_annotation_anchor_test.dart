import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports — parseSync is the only pure-Dart entry point
// into the hit map. The public barrel reaches it only through the FFI service,
// which cannot run headless.
import 'package:verovio_flutter/src/hit_map/parser.dart';
import 'package:verovio_flutter/verovio_flutter.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';

/// What the hit map actually reports for Verovio's own annotation elements.
///
/// This is the evidence the "let Verovio own vertical space" design rests on, so
/// it is a test rather than a spike: if a plugin or Verovio upgrade changes any
/// of it, this fails instead of the staff quietly going wrong.
///
/// Fixtures are real Verovio 6.2.0 output over the project's own MusicXML,
/// engraved at `scale: 40, pageWidth: 1975` — the engraver's probe settings. See
/// `test/fixtures/verovio_*.svg`.
///
/// ## The two facts that matter
///
/// 1. **Position is accurate, extent is not.** The walker has no `<tspan>`
///    handling (`verovio_flutter-0.3.1/lib/src/hit_map/walker.dart:380`); it reads
///    `font-size` off the `<text>`, which Verovio always sets to `"0px"`, so it
///    falls back to 16 units and reports a ~0.6×0.7px box for a glyph that really
///    inks ~12px. But `x`/`y` are read straight off the attributes and correctly
///    transformed, so the ANCHOR is trustworthy even though the box is not.
/// 2. **Annotations form a near-flat register per system.** Verovio places each
///    fingering by its notehead, so the row is not perfectly level — but the
///    spread is under a couple of staff spaces, not the staff's whole range,
///    which is what makes a drawn flat register viable.
void main() {
  /// The engraver's probe options, which the fixtures were generated with.
  const pageWidthUnits = 1975;

  List<ElementHit> of(PageHitMap m, String type) =>
      m.byId.values.where((h) => h.type == type).toList();

  /// The app's own staff-space formula, in fixture coordinates:
  /// `staffHeight = staffHeightUnits × engravedScale / 100`, four spaces to it.
  double staffSpaceOf(PageHitMap m) =>
      staffHeightUnits * (m.viewBox.width * 100 / pageWidthUnits) / 100 / 4;

  /// Per system line, the annotation baselines on it — grouped with the app's
  /// own [systemLinesOf] over the (accurately measured) measure boxes, which is
  /// exactly how the real code will have to do it.
  List<List<double>> baselinesByLine(
      PageHitMap map, List<ElementHit> annotations) {
    final measures = of(map, 'measure')
      ..sort((a, b) {
        final v = a.bbox.top.compareTo(b.bbox.top);
        return v != 0 ? v : a.bbox.left.compareTo(b.bbox.left);
      });
    final rects = [for (final m in measures) m.bbox];
    final (lineOf, _) = systemLinesOf(rects);
    final lines = lineOf.isEmpty ? 0 : lineOf.reduce(math.max) + 1;
    // Union each line's measure boxes, then claim the annotations inside it.
    final bounds = <int, Rect>{};
    for (var i = 0; i < rects.length; i++) {
      final l = lineOf[i];
      bounds[l] = bounds[l] == null ? rects[i] : bounds[l]!.expandToInclude(rects[i]);
    }
    final out = [for (var l = 0; l < lines; l++) <double>[]];
    for (final a in annotations) {
      for (var l = 0; l < lines; l++) {
        final b = bounds[l];
        if (b == null) continue;
        if (a.bbox.top >= b.top && a.bbox.top <= b.bottom) {
          out[l].add(a.bbox.top);
          break;
        }
      }
    }
    for (final l in out) {
      l.sort();
    }
    return out;
  }

  group('fingerings', () {
    late PageHitMap map;

    setUp(() {
      map = HitMapParser.parseSync(
        File('test/fixtures/verovio_fing.svg').readAsStringSync(),
        config: const ParseConfig(
          captureClasses: {'fing', 'note', 'measure'},
        ),
      );
    });

    test('MusicXML <fingering> is engraved and capturable as class="fing"', () {
      // 54 <fingering> elements in assets/fixtures/happy_farmer_musescore.xml.
      expect(of(map, 'fing'), hasLength(54));
    });

    test('every fingering is horizontally aligned with a notehead', () {
      final notes = of(map, 'note');
      final fings = of(map, 'fing');
      for (final f in fings) {
        expect(
          notes.any((n) => (n.bbox.center.dx - f.bbox.left).abs() < 4),
          isTrue,
          reason: 'fing at x=${f.bbox.left} has no notehead near it',
        );
      }
    });

    test('baselines form a near-flat register on each system', () {
      final space = staffSpaceOf(map);
      final byLine = baselinesByLine(map, of(map, 'fing'));
      final populated = byLine.where((l) => l.length > 1).toList();
      expect(populated, isNotEmpty, reason: 'no system carried fingerings');
      for (final ys in populated) {
        final spread = (ys.last - ys.first) / space;
        // Measured 1.7–1.8 spaces on Happy Farmer. A drawn flat register is
        // viable at this spread; it would not be if fingerings tracked pitch
        // across the staff's whole range.
        expect(spread, lessThan(3.0),
            reason: 'spread ${spread.toStringAsFixed(2)} staff spaces');
      }
    });

    // Guards the quirk the design deliberately relies on. If a plugin upgrade
    // ever fixes <tspan> handling this fails, and the extent becomes usable.
    test('reported extent is the bogus font-size fallback, not the real glyph',
        () {
      final space = staffSpaceOf(map);
      for (final f in of(map, 'fing')) {
        expect(f.bbox.height, lessThan(space * 0.25),
            reason: 'extent looks real now — revisit annotationFontSizeFor');
      }
    });
  });

  group('chord symbols', () {
    late PageHitMap map;

    setUp(() {
      map = HitMapParser.parseSync(
        File('test/fixtures/verovio_harm.svg').readAsStringSync(),
        config: const ParseConfig(captureClasses: {'harm', 'measure'}),
      );
    });

    test('MusicXML <harmony> is engraved and capturable as class="harm"', () {
      // 9 <harmony> elements in assets/fixtures/lightly_row_musescore.xml.
      expect(of(map, 'harm'), hasLength(9));
    });

    test('baselines are exactly level on each system', () {
      final byLine = baselinesByLine(map, of(map, 'harm'));
      final populated = byLine.where((l) => l.length > 1).toList();
      expect(populated, isNotEmpty);
      for (final ys in populated) {
        // Chord symbols share one baseline per system — a true register, which
        // is stronger than the fingerings' near-flat one.
        expect(ys.last - ys.first, lessThan(0.5),
            reason: 'chord baselines differ within a system: $ys');
      }
    });
  });
}

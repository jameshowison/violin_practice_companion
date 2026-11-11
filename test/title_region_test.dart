import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/title_region.dart';

/// A smooth synthetic "page": a sum of random Gaussian blobs, so it has
/// structure at every scale (like print) and downsampling does not destroy
/// it as it would pure noise.
GrayThumb _page(int w, int h, {int seed = 1}) {
  final r = math.Random(seed);
  final blobs = [
    for (var i = 0; i < 60; i++)
      (r.nextDouble() * w, r.nextDouble() * h, 10 + r.nextDouble() * 60, r.nextDouble() * 200 - 100)
  ];
  final lum = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 128.0;
      for (final (bx, by, s, a) in blobs) {
        final dx = x - bx, dy = y - by;
        v += a * math.exp(-(dx * dx + dy * dy) / (2 * s * s));
      }
      lum[y * w + x] = v;
    }
  }
  return GrayThumb(w, h, lum, sourceWidth: w, sourceHeight: h);
}

GrayThumb _sub(GrayThumb g, int x0, int y0, int w, int h) {
  final lum = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      lum[y * w + x] = g.at(x0 + x, y0 + y);
    }
  }
  return GrayThumb(w, h, lum, sourceWidth: w, sourceHeight: h);
}

/// Thumbnail the way grayThumb does: area-averaged to [longSide], keeping the
/// full-size dimensions as the source size.
GrayThumb _thumb(GrayThumb full, int longSide, {int? sourceWidth, int? sourceHeight}) {
  final s = longSide / math.max(full.width, full.height);
  final t = full.resized((full.width * s).round(), (full.height * s).round());
  return GrayThumb(t.width, t.height, t.lum,
      sourceWidth: sourceWidth ?? full.width, sourceHeight: sourceHeight ?? full.height);
}

void expectRect(ui.Rect? got, ui.Rect want, {double tol = 0.02}) {
  expect(got, isNotNull);
  expect(got!.left, closeTo(want.left, tol), reason: 'left of $got');
  expect(got.top, closeTo(want.top, tol), reason: 'top of $got');
  expect(got.width, closeTo(want.width, tol), reason: 'width of $got');
  expect(got.height, closeTo(want.height, tol), reason: 'height of $got');
}

void main() {
  group('locateCrop', () {
    final full = _page(800, 1100);

    test('finds a crop at its offset', () {
      final crop = _sub(full, 60, 520, 640, 300);
      expectRect(locateCrop(_thumb(full, 256), _thumb(crop, 512)),
          const ui.Rect.fromLTWH(60 / 800, 520 / 1100, 640 / 800, 300 / 1100));
    });

    test('finds a small crop', () {
      final crop = _sub(full, 400, 100, 250, 180);
      expectRect(locateCrop(_thumb(full, 256), _thumb(crop, 512)),
          const ui.Rect.fromLTWH(400 / 800, 100 / 1100, 250 / 800, 180 / 1100));
    });

    test('a crop the size of the page is the whole page', () {
      expect(locateCrop(_thumb(full, 256), _thumb(full, 512)),
          const ui.Rect.fromLTWH(0, 0, 1, 1));
    });

    test('finds a crop the cropper scaled down at its size cap', () {
      // A 4900 × 3500 crop of a 5600 × 7700 page, which the cropper shrank
      // to 4000 wide: its pixel size no longer says how big it was.
      final crop = _sub(full, 50, 300, 700, 500);
      final page = _thumb(full, 256, sourceWidth: 800 * 7, sourceHeight: 1100 * 7);
      final capped = _thumb(crop, 512, sourceWidth: 4000, sourceHeight: (4000 * 500 / 700).round());
      expectRect(locateCrop(page, capped),
          const ui.Rect.fromLTWH(50 / 800, 300 / 1100, 700 / 800, 500 / 1100),
          tol: 0.04);
    });

    test('an unrelated image is no match', () {
      final other = _sub(_page(800, 1100, seed: 99), 100, 100, 500, 300);
      expect(locateCrop(_thumb(full, 256), _thumb(other, 512)), isNull);
    });
  });

  group('titleSearchRegion', () {
    test('reaches above and into the crop, with side margins', () {
      final r = titleSearchRegion(const ui.Rect.fromLTWH(0.2, 0.5, 0.6, 0.4));
      expect(r.top, closeTo(0.5 - titleAboveCrop, 1e-9));
      expect(r.bottom, closeTo(0.5 + titleIntoCrop * 0.4, 1e-9));
      expect(r.left, closeTo(0.2 - titleSideMargin, 1e-9));
      expect(r.right, closeTo(0.8 + titleSideMargin, 1e-9));
    });

    test('clamps to the page', () {
      final r = titleSearchRegion(const ui.Rect.fromLTWH(0, 0, 1, 1));
      expect(r, ui.Rect.fromLTRB(0, 0, 1, titleIntoCrop));
    });
  });

  group('pickTitle', () {
    RecognizedLine line(String t, double h, {double c = 0.9, double top = 0.1}) =>
        RecognizedLine(t, c, ui.Rect.fromLTWH(0.1, top, 0.5, h));

    test('prefers the largest type over the composer line', () {
      expect(pickTitle([line('S. Suzuki', 0.012), line('Allegretto', 0.03)]), 'Allegretto');
    });

    test('skips numbers and tempo marks however big', () {
      expect(
          pickTitle([line('14', 0.05), line('39', 0.04), line('♩ = 60', 0.05), line('Minuet No. 2', 0.03)]),
          'Minuet No. 2');
    });

    test('a long title beats the short tempo mark in smaller type', () {
      expect(pickTitle([line('Go Tell Aunt Rhody', 0.07), line('Andantino', 0.045)]),
          'Go Tell Aunt Rhody');
    });

    test('of two lines in the same size of type, the upper one', () {
      expect(
          pickTitle([
            line('Vas le dire à tante Rhody Tante Rhody', 0.073, top: 0.12),
            line('Go Tell Aunt Rhody', 0.072, top: 0.05),
          ]),
          'Go Tell Aunt Rhody');
    });

    test('skips notation noise that is mostly not letters', () {
      expect(pickTitle([line('• P..li б.', 0.074), line('Minuet No. 3', 0.028)]), 'Minuet No. 3');
    });

    test('skips prose: footnotes and merged translation lines', () {
      expect(
          pickTitle([
            line('The notes at the beginning of the piece are on the upbeat, play them lightly.', 0.018,
                top: 0.33),
            line('Andantino', 0.017, top: 0.44),
          ]),
          'Andantino');
    });

    test('skips other scripts and trims stray marks', () {
      expect(pickTitle([line('одідекдто;', 0.073), line('-°Chorus from Judas Maccabaeus', 0.025)]),
          'Chorus from Judas Maccabaeus');
    });

    test('keeps punctuation and tidies whitespace', () {
      expect(pickTitle([line('  Go Tell  Aunt Rhody ', 0.03)]), 'Go Tell Aunt Rhody');
    });

    test('ignores low-confidence reads', () {
      expect(pickTitle([line('Xqzzv blah', 0.08, c: 0.1), line('Andantino', 0.03)]), 'Andantino');
    });

    test('null when nothing qualifies', () {
      expect(pickTitle([]), isNull);
      expect(pickTitle([line('mf', 0.02)]), isNull);
    });
  });
}

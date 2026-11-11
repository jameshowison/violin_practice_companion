import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Where to look for a scanned piece's title, and which line of text it is.
///
/// Python homr OCRs a strip above the top staff and keeps the line in the
/// largest type (`homr/title_detection.py`); homr_flutter did not port that.
/// Here the strip is found from the user's music crop instead: the cropper
/// returns only the cropped pixels, so [locateCrop] finds them again in the
/// original page, [titleSearchRegion] widens that to where a title sits, and
/// [pickTitle] applies homr's rule to whatever the OCR read there.
///
/// Pure Dart and `dart:ui` only — the OCR itself is platform-specific (see
/// `title_recognizer.dart`).

/// A small greyscale copy of an image: [lum] holds [width] × [height] values,
/// row-major, 0–255. [sourceWidth]/[sourceHeight] are the full image's upright
/// pixel size, which fixes the scale between two thumbnails.
class GrayThumb {
  final int width;
  final int height;
  final Float32List lum;
  final int sourceWidth;
  final int sourceHeight;
  const GrayThumb(this.width, this.height, this.lum,
      {required this.sourceWidth, required this.sourceHeight});

  double at(int x, int y) => lum[y * width + x];

  /// Area-averaged resample to [w] × [h] (each output pixel is the mean of
  /// the source pixels it covers), so a large downscale does not alias.
  GrayThumb resized(int w, int h) {
    final out = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      final y0 = (y * height / h).floor();
      final y1 = math.max(y0 + 1, ((y + 1) * height / h).floor());
      for (var x = 0; x < w; x++) {
        final x0 = (x * width / w).floor();
        final x1 = math.max(x0 + 1, ((x + 1) * width / w).floor());
        var sum = 0.0;
        for (var sy = y0; sy < y1 && sy < height; sy++) {
          for (var sx = x0; sx < x1 && sx < width; sx++) {
            sum += lum[sy * width + sx];
          }
        }
        out[y * w + x] = sum / ((math.min(y1, height) - y0) * (math.min(x1, width) - x0));
      }
    }
    return GrayThumb(w, h, out, sourceWidth: sourceWidth, sourceHeight: sourceHeight);
  }
}

/// Decodes [bytes] (PNG or JPEG) to a [GrayThumb] whose longer side is about
/// [longSide] pixels. The platform decoder applies EXIF orientation, as
/// `UIImage` and the cropper do, so every thumbnail is of the upright image.
Future<GrayThumb> grayThumb(Uint8List bytes, {int longSide = 256}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  var w = descriptor.width, h = descriptor.height;
  // Decode at twice the size and area-average down (below), so page and crop
  // thumbnails go through the same filter whatever the codec's own is.
  final scale = math.min(1.0, 2 * longSide / math.max(w, h));
  final codec = await descriptor.instantiateCodec(
    targetWidth: math.max(1, (w * scale).round()),
    targetHeight: math.max(1, (h * scale).round()),
  );
  final image = (await codec.getNextFrame()).image;
  // The descriptor reports the stored size; if EXIF rotated the image by a
  // quarter turn, the decoded aspect comes out inverted, so swap.
  if ((image.width > image.height) != (w > h) && w != h) {
    final t = w;
    w = h;
    h = t;
  }
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final lum = Float32List(image.width * image.height);
  for (var i = 0; i < lum.length; i++) {
    final o = i * 4;
    lum[i] = 0.299 * rgba.getUint8(o) + 0.587 * rgba.getUint8(o + 1) + 0.114 * rgba.getUint8(o + 2);
  }
  final thumb = GrayThumb(image.width, image.height, lum, sourceWidth: w, sourceHeight: h);
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  final down = longSide / math.max(thumb.width, thumb.height);
  if (down >= 1) return thumb;
  return thumb.resized(
      math.max(1, (thumb.width * down).round()), math.max(1, (thumb.height * down).round()));
}

/// The cropper's output size cap (`omr_service_io.dart`, `maxWidth`/`maxHeight`).
/// A crop at the cap may have been scaled down, so its size in the original is
/// unknown and [locateCrop] has to search over scales.
const cropperSizeCap = 4000;

/// Below this normalised cross-correlation the match is not trusted.
const _minMatchScore = 0.6;

/// Finds [crop] inside [page] and returns its rect, normalised to the page
/// (0–1, top-left origin), or null if no confident match. A crop the size of
/// the page — the user kept everything, or picked an already-cropped photo —
/// is the whole page.
ui.Rect? locateCrop(GrayThumb page, GrayThumb crop) {
  if (crop.sourceWidth == page.sourceWidth && crop.sourceHeight == page.sourceHeight) {
    return const ui.Rect.fromLTWH(0, 0, 1, 1);
  }
  // Thumbnail pixels per source pixel of the page.
  final s = page.width / page.sourceWidth;
  final baseW = crop.sourceWidth * s, baseH = crop.sourceHeight * s;

  // Scale factors (crop pixels per page pixel) to try. Below the cap the
  // cropper does not resize, so the crop is at the page's own scale.
  final capped = math.max(crop.sourceWidth, crop.sourceHeight) >= cropperSizeCap - 1;
  final factors = <double>[1.0];
  if (capped) {
    // Largest the crop can be: the whole page.
    final maxGrow = math.min(page.width / baseW, page.height / baseH);
    for (var i = 1; i <= 16; i++) {
      factors.add(1 + (maxGrow - 1) * i / 16);
    }
  }

  ui.Rect? best;
  var bestScore = -2.0;
  for (final f in factors) {
    final w = math.min(page.width, (baseW * f).round());
    final h = math.min(page.height, (baseH * f).round());
    if (w < 4 || h < 4) continue;
    final t = crop.resized(w, h);
    final m = _bestOffset(page, t);
    if (m.score > bestScore) {
      bestScore = m.score;
      best = ui.Rect.fromLTWH(
          m.x / page.width, m.y / page.height, w / page.width, h / page.height);
    }
  }
  return bestScore >= _minMatchScore ? best : null;
}

/// Exhaustive normalised cross-correlation of [t] over every offset in [page],
/// sampling every second template pixel. Thumbnails are ~256 px, so this is
/// around 10⁷ multiply-adds.
({int x, int y, double score}) _bestOffset(GrayThumb page, GrayThumb t) {
  const step = 2;
  final xs = <int>[for (var x = 0; x < t.width; x += step) x];
  final ys = <int>[for (var y = 0; y < t.height; y += step) y];
  final n = xs.length * ys.length;
  final tv = Float32List(n);
  var k = 0, tMean = 0.0;
  for (final y in ys) {
    for (final x in xs) {
      tv[k] = t.at(x, y);
      tMean += tv[k++];
    }
  }
  tMean /= n;
  var tVar = 0.0;
  for (var i = 0; i < n; i++) {
    tv[i] -= tMean;
    tVar += tv[i] * tv[i];
  }
  if (tVar == 0) return (x: 0, y: 0, score: -1); // a blank crop matches anywhere

  var best = (x: 0, y: 0, score: -2.0);
  final pw = page.width;
  final p = page.lum;
  for (var oy = 0; oy <= page.height - t.height; oy++) {
    for (var ox = 0; ox <= pw - t.width; ox++) {
      var sumP = 0.0, sumP2 = 0.0, sumPT = 0.0;
      var i = 0;
      for (final y in ys) {
        final row = (oy + y) * pw + ox;
        for (final x in xs) {
          final v = p[row + x];
          sumP += v;
          sumP2 += v * v;
          sumPT += v * tv[i++];
        }
      }
      final pVar = sumP2 - sumP * sumP / n;
      if (pVar <= 0) continue;
      // tv is zero-mean, so sumPT is already the covariance term.
      final score = sumPT / math.sqrt(pVar * tVar);
      if (score > best.score) best = (x: ox, y: oy, score: score);
    }
  }
  return best;
}

/// How far above the crop's top edge to look, as a fraction of the page
/// height: room for a title plus the subtitle/composer line under it.
const titleAboveCrop = 0.18;

/// How far down into the crop to look, as a fraction of the crop's height:
/// many crops keep their own title, and a pre-cropped photo has nowhere
/// "above" at all.
const titleIntoCrop = 0.3;

/// Horizontal slack on each side of the crop, as a fraction of the page width
/// — a title can be wider than the music under it, or centred over it.
const titleSideMargin = 0.05;

/// The part of the page to OCR for the title of the music in [crop]
/// (normalised, top-left origin, clamped to the page).
ui.Rect titleSearchRegion(ui.Rect crop) {
  final top = math.max(0.0, crop.top - titleAboveCrop);
  final bottom = math.min(1.0, crop.top + titleIntoCrop * crop.height);
  final left = math.max(0.0, crop.left - titleSideMargin);
  final right = math.min(1.0, crop.right + titleSideMargin);
  return ui.Rect.fromLTRB(left, top, right, bottom);
}

/// One line of text the OCR read: its [box] is normalised to the page.
class RecognizedLine {
  final String text;
  final double confidence;
  final ui.Rect box;
  const RecognizedLine(this.text, this.confidence, this.box);

  @override
  String toString() => 'RecognizedLine("$text", $confidence, $box)';
}

/// Fewer letters than this and a line is a tempo mark, page or piece number,
/// or dynamic rather than a title (homr's `is_tempo_marking`).
const _minTitleLetters = 4;

/// Lines whose non-space characters are less than this share letters are OCR
/// noise from notation ("• P..li", "3+4"), not words.
const _minLetterShare = 0.6;

/// Longer lines are prose — footnotes from the piece above, or the merged
/// line of translated titles — not a title.
const _maxTitleLength = 50;

/// Lines within this fraction of the biggest type count as the same size; the
/// topmost of them wins, as a title sits above anything set like it.
const _sameSizeTolerance = 0.05;

/// OCR guesses below this confidence are ignored.
const _minConfidence = 0.3;

/// Latin letters only: the books are English with European translations, and
/// pencil marks read as other scripts are noise.
final _letter = RegExp(r'\p{Script=Latin}', unicode: true);

/// Stray marks OCR attaches to either end of a title ("-°Chorus from …").
final _edgeJunk = RegExp(r'^[^\p{L}\p{N}"“(¡¿]+|[^\p{L}\p{N}.)"”!?]+$', unicode: true);

final _space = RegExp(r'\s+');

/// The title among [lines]: the line in the largest type (box height),
/// ignoring numbers, tempo marks and notation noise, the topmost if several
/// are about equally large. Punctuation is kept, so "Minuet No. 2" reads as
/// printed. Null if nothing qualifies.
///
/// homr scores by box height per character instead, which measured badly on
/// the dev library: it favours short words, so the tempo mark under a title
/// ("Andantino" under "Go Tell Aunt Rhody") won 5 of 19 pages.
String? pickTitle(List<RecognizedLine> lines) {
  final candidates = [
    for (final line in lines)
      if (_isWordy(line)) line,
  ];
  if (candidates.isEmpty) return null;
  final biggest = candidates.map((l) => l.box.height).reduce(math.max);
  final top = candidates
      .where((l) => l.box.height >= biggest * (1 - _sameSizeTolerance))
      .reduce((a, b) => b.box.top < a.box.top ? b : a);
  return _tidy(top.text);
}

String _tidy(String text) => text.replaceAll(_edgeJunk, '').trim().replaceAll(_space, ' ');

bool _isWordy(RecognizedLine line) {
  if (line.confidence < _minConfidence) return false;
  if (_tidy(line.text).length > _maxTitleLength) return false;
  final text = line.text.replaceAll(_space, '');
  final letters = _letter.allMatches(text).length;
  return letters >= _minTitleLetters && letters >= _minLetterShare * text.length;
}

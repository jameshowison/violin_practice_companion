import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:homr_flutter/homr_flutter.dart';

import 'bundled_asset_path.dart';
import 'title_recognizer_base.dart';
import 'title_region.dart';

/// Finds the crop in the page, then reads the strip around its top edge with
/// homr_flutter's [TextReader]: PaddleOCR's open models on ONNX Runtime, the
/// same on iOS and Android. Any failure, such as missing models, gives a null
/// title.
///
/// It replaced Apple Vision and Google ML Kit (closed, so not GPL-clean) on
/// 2026-11-18, reading 14/22 titles of the dev-library corpus to their 13 and
/// 11 (docs/title_ocr.md). Both platform plugins are in git history at
/// 8b18b5a, should a comparison ever be wanted again.
class TitleRecognizer implements TitleRecognizerBase {
  /// PaddleOCR's two models, put there by scripts/fetch_omr_models.sh, and
  /// opened in place where the platform allows.
  static final ocrModels =
      OcrModels.inAssetDir('assets/engine/ocr_models', resolvePath: bundledAssetPath);

  @override
  Future<String?> recognise({required Uint8List original, required Uint8List cropped}) async {
    try {
      final crop = await locateCropIn(original, cropped);
      // No confident match: assume the crop is the page, which still searches
      // the top of the image, where a pre-cropped photo keeps its title.
      final region = titleSearchRegion(crop ?? const ui.Rect.fromLTWH(0, 0, 1, 1));
      final lines = await readLines(original, region);
      return pickTitle(lines);
    } catch (e) {
      debugPrint('[title] recognition failed: $e');
      return null;
    }
  }

  /// [locateCrop] on thumbnails of the two images.
  static Future<ui.Rect?> locateCropIn(Uint8List original, Uint8List cropped) async {
    final page = await grayThumb(original);
    final crop = await grayThumb(cropped, longSide: 512); // area-resized to the page's scale in locateCrop
    return locateCrop(page, crop);
  }

  /// The lines of text in [region] of [image] that [pickTitle] needs, a
  /// leading page number dropped from each. Lines are read largest type
  /// first, stopping once the largest [isTitleCandidate] and every line about
  /// its size are read: on a busy page that is 1–3 lines instead of up to 80
  /// (median 667 ms instead of 1.8 s on the 4 GB Android emulator,
  /// docs/title_ocr.md). A reader per call, disposed at once: the title is
  /// read just before the score is recognised, and the music models need the
  /// memory.
  static Future<List<RecognizedLine>> readLines(Uint8List image, ui.Rect region) async {
    RecognizedLine toLine(OcrLine l) =>
        RecognizedLine(dropLeadingPageNumber(l.text), l.confidence, l.box);
    final reader = TextReader(ocrModels);
    try {
      return [
        for (final l in await reader.readText(image,
            region: region,
            accept: (l) => isTitleCandidate(toLine(l)),
            sameSizeTolerance: titleSameSizeTolerance))
          toLine(l),
      ];
    } finally {
      await reader.dispose();
    }
  }
}

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'title_recognizer_base.dart';
import 'title_region.dart';

/// Finds the crop in the page, then asks the native text recogniser to read
/// the strip around its top edge. iOS (`ios/Runner/TextRecognitionPlugin.swift`,
/// Apple Vision) and Android (`TextRecognitionPlugin.kt`, ML Kit) have a
/// handler; elsewhere the channel call fails with MissingPluginException and
/// the result is null.
class TitleRecognizer implements TitleRecognizerBase {
  static const _channel = MethodChannel('violin_practice_companion/text_recognition');

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

  /// Every line the native OCR reads in [region] of [image].
  static Future<List<RecognizedLine>> readLines(Uint8List image, ui.Rect region) async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('recognizeText', {
      'image': image,
      'region': [region.left, region.top, region.width, region.height],
    });
    return [
      for (final m in raw ?? const <Map<Object?, Object?>>[])
        RecognizedLine(
          m['text'] as String,
          (m['confidence'] as num).toDouble(),
          () {
            final b = (m['box'] as List).cast<num>();
            return ui.Rect.fromLTWH(
                b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble());
          }(),
        ),
    ];
  }
}

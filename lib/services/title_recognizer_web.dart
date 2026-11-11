import 'dart:typed_data';

import 'title_recognizer_base.dart';

/// Web: scanning is not available on web at all (`omr_service_web.dart`).
class TitleRecognizer implements TitleRecognizerBase {
  @override
  Future<String?> recognise({required Uint8List original, required Uint8List cropped}) async =>
      null;
}

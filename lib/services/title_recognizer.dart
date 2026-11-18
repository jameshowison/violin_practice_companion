// iOS uses Apple Vision (ios/Runner/TextRecognitionPlugin.swift), Android ML
// Kit (TextRecognitionPlugin.kt); where there is no handler the scan gets no
// title and falls back to a dated default.
export 'title_recognizer_base.dart';
export 'title_recognizer_io.dart';

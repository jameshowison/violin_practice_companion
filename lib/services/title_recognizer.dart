// iOS uses Apple Vision (ios/Runner/TextRecognitionPlugin.swift); web and the
// platforms without a native handler yet get no title, and the scan falls
// back to a dated default.
export 'title_recognizer_base.dart';
export 'title_recognizer_io.dart' if (dart.library.html) 'title_recognizer_web.dart';

// Titles are read in Dart with homr_flutter's TextReader (PaddleOCR on ONNX
// Runtime) on both platforms; with no models, or any failure, the scan gets
// no title and falls back to a dated default.
export 'title_recognizer_base.dart';
export 'title_recognizer_io.dart';

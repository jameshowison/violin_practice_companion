import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Writes [pdf] to `Documents/print_debug.pdf` (debug builds only).
Future<void> dumpPrintedPdf(Uint8List pdf) async {
  if (!kDebugMode) return;
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/print_debug.pdf');
  await file.writeAsBytes(pdf, flush: true);
  debugPrint('[print] wrote ${pdf.length} bytes to ${file.path}');
}

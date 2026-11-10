import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Writes [wav] to a temporary file and returns its path.
Future<String?> writeCalibrationClip(Uint8List wav,
    {String name = 'sync_calibration.wav'}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(wav, flush: true);
  return file.path;
}

import 'dart:typed_data';

/// No file system on the web: calibration is unavailable.
Future<String?> writeCalibrationClip(Uint8List wav,
    {String name = 'sync_calibration.wav'}) async => null;

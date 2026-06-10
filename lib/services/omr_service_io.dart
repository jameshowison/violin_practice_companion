import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:homr_omr/homr_omr.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';

import 'omr_service_base.dart';

/// Mobile/desktop scan-to-MusicXML pipeline: document scanner →
/// `preprocessImage` (binarize) → crop to the music region → `homr_omr`
/// recognition.
class OmrService implements OmrServiceBase {
  static const _contentResolverChannel = MethodChannel('dev.homr/content_resolver');

  @override
  Future<String?> scan({
    void Function(OmrScanStage stage)? onProgress,
    String title = '',
  }) async {
    onProgress?.call(OmrScanStage.capturing);
    final result = await FlutterDocScanner().getScannedDocumentAsImages(
      page: 1,
      imageFormat: ImageFormat.jpeg,
    );
    if (result == null || result.images.isEmpty) return null;

    final scanned = await _resolveToFile(result.images.first);

    onProgress?.call(OmrScanStage.preprocessing);
    final jpegBytes = await scanned.readAsBytes();
    final preprocessed = await preprocessImage(jpegBytes);

    onProgress?.call(OmrScanStage.cropping);
    final croppedBytes = await _cropToMusic(preprocessed.thresholded);
    if (croppedBytes == null) return null;

    return OmrOrchestrator().recognise(
      croppedBytes,
      title: title,
      onProgress: (stage) => onProgress?.call(switch (stage) {
        OmrStage.segmenting => OmrScanStage.segmenting,
        OmrStage.detecting => OmrScanStage.detecting,
        OmrStage.recognising => OmrScanStage.recognising,
        OmrStage.assembling => OmrScanStage.assembling,
      }),
    );
  }

  Future<Uint8List?> _cropToMusic(Uint8List thresholdedPng) async {
    final dir = await getTemporaryDirectory();
    final source = File('${dir.path}/omr_threshold_${DateTime.now().millisecondsSinceEpoch}.png');
    await source.writeAsBytes(thresholdedPng);

    final cropped = await ImageCropper().cropImage(
      sourcePath: source.path,
      uiSettings: [
        IOSUiSettings(
          title: 'Crop to Music',
          doneButtonTitle: 'Done',
          cancelButtonTitle: 'Cancel',
          rotateButtonsHidden: true,
          resetButtonHidden: true,
          aspectRatioLockEnabled: false,
        ),
      ],
    );
    if (cropped == null) return null;
    return cropped.readAsBytes();
  }

  /// On iOS the scanner returns a direct file path; on Android it returns a
  /// content:// URI. Copy to the app cache dir so the rest of the pipeline
  /// always receives a regular File.
  Future<File> _resolveToFile(String path) async {
    if (!path.startsWith('content://')) return File(path);

    final bytes = await _contentResolverChannel.invokeMethod<Uint8List>('readBytes', {'uri': path});
    if (bytes == null) throw Exception('Failed to read content URI: $path');

    final dir = await getTemporaryDirectory();
    final dest = File('${dir.path}/scan_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await dest.writeAsBytes(bytes);
    return dest;
  }
}

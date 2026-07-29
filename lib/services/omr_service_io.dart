import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:homr_omr/homr_omr.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import 'omr_service_base.dart';

/// Mobile/desktop scan-to-MusicXML pipeline: acquire a page image (document
/// scanner, photo library, or file/PDF) → `preprocessImage` (binarize) → crop
/// to the music region → `homr_omr` recognition.
class OmrService implements OmrServiceBase {
  static const _contentResolverChannel = MethodChannel('dev.homr/content_resolver');

  @override
  Future<String?> scan({
    OmrImageSource source = OmrImageSource.camera,
    void Function(OmrScanStage stage)? onProgress,
    String title = '',
    Future<int?> Function(int pageCount)? onSelectPdfPage,
  }) async {
    onProgress?.call(OmrScanStage.capturing);
    final imageBytes = await _acquire(source, onSelectPdfPage: onSelectPdfPage);
    if (imageBytes == null) return null;

    onProgress?.call(OmrScanStage.preprocessing);
    final preprocessed = await preprocessImage(imageBytes);

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

  /// Acquire the raw page-image bytes (JPEG or PNG) from the chosen [source].
  /// Returns null if the user cancels the picker. `preprocessImage` decodes
  /// either format, so no conversion is needed here.
  Future<Uint8List?> _acquire(
    OmrImageSource source, {
    Future<int?> Function(int pageCount)? onSelectPdfPage,
  }) async {
    switch (source) {
      case OmrImageSource.camera:
        return _acquireFromCamera();
      case OmrImageSource.photoLibrary:
        return _acquireFromPhotos();
      case OmrImageSource.file:
        return _acquireFromFile(onSelectPdfPage: onSelectPdfPage);
    }
  }

  Future<Uint8List?> _acquireFromCamera() async {
    // VisionKit's VNDocumentCameraViewController (used by flutter_doc_scanner)
    // is unsupported on the iOS Simulator / Android emulator — its initializer
    // throws an uncatchable ObjC NSException that aborts the whole app. Detect
    // a non-physical device and fail with a friendly message the ScanScreen can
    // show instead. Use Photos or File to scan in the simulator.
    if (!await _isPhysicalDevice()) {
      throw UnsupportedError(
        'Camera scanning needs a real device — a simulator/emulator has no '
        'document camera. Use "Choose from Photos" or "Choose File" instead.',
      );
    }

    final result = await FlutterDocScanner().getScannedDocumentAsImages(
      page: 1,
      imageFormat: ImageFormat.jpeg,
    );
    if (result == null || result.images.isEmpty) return null;
    final scanned = await _resolveToFile(result.images.first);
    return scanned.readAsBytes();
  }

  /// Whether we're running on real hardware (vs simulator/emulator). Only iOS
  /// and Android have the document camera; other platforms return true so the
  /// camera path is attempted and fails through the plugin normally.
  Future<bool> _isPhysicalDevice() async {
    final info = DeviceInfoPlugin();
    if (Platform.isIOS) return (await info.iosInfo).isPhysicalDevice;
    if (Platform.isAndroid) return (await info.androidInfo).isPhysicalDevice;
    return true;
  }

  Future<Uint8List?> _acquireFromPhotos() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return null;
    return picked.readAsBytes();
  }

  Future<Uint8List?> _acquireFromFile({
    Future<int?> Function(int pageCount)? onSelectPdfPage,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
    );
    final file = result?.files.singleOrNull;
    if (file == null) return null;

    final bytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) return null;

    final isPdf = (file.extension ?? '').toLowerCase() == 'pdf';
    if (isPdf) return _rasterizePdf(bytes, onSelectPdfPage: onSelectPdfPage);
    return bytes;
  }

  /// Render one page of a PDF to PNG bytes for the OMR pipeline. For a
  /// multi-page document, [onSelectPdfPage] chooses the 0-based page index
  /// (null → user cancelled); with no callback or a single page, page 0 is
  /// used. Renders at [_pdfTargetWidth] px wide to match `preprocessImage`'s
  /// own resize target.
  static const _pdfTargetWidth = 1920.0;

  Future<Uint8List?> _rasterizePdf(
    Uint8List pdfBytes, {
    Future<int?> Function(int pageCount)? onSelectPdfPage,
  }) async {
    final document = await PdfDocument.openData(pdfBytes);
    try {
      var pageIndex = 0; // 0-based
      if (document.pagesCount > 1 && onSelectPdfPage != null) {
        final chosen = await onSelectPdfPage(document.pagesCount);
        if (chosen == null) return null; // user cancelled the page picker
        pageIndex = chosen.clamp(0, document.pagesCount - 1);
      }

      final page = await document.getPage(pageIndex + 1); // pdfx is 1-based
      try {
        final scale = _pdfTargetWidth / page.width;
        final rendered = await page.render(
          width: _pdfTargetWidth,
          height: page.height * scale,
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        return rendered?.bytes;
      } finally {
        await page.close();
      }
    } finally {
      await document.close();
    }
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

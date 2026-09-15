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

/// Mobile/desktop scan-to-MusicXML pipeline: acquire every page's image
/// (document scanner, photo library, or file/PDF) → `preprocessImage`
/// (binarize) → crop each page to the music region → `homr_omr` recognition,
/// concatenated across pages into one piece.
class OmrService implements OmrServiceBase {
  static const _contentResolverChannel = MethodChannel('dev.homr/content_resolver');

  @override
  Future<String?> scan({
    OmrImageSource source = OmrImageSource.camera,
    void Function(OmrScanStage stage)? onProgress,
    String title = '',
  }) async {
    onProgress?.call(OmrScanStage.capturing);
    final pages = await _acquire(source);
    if (pages == null || pages.isEmpty) return null;

    onProgress?.call(OmrScanStage.preprocessing);
    final preprocessedPages = <Uint8List>[];
    for (final bytes in pages) {
      preprocessedPages.add((await preprocessImage(bytes)).thresholded);
    }

    onProgress?.call(OmrScanStage.cropping);
    final croppedPages = <Uint8List>[];
    for (var i = 0; i < preprocessedPages.length; i++) {
      final cropped = await _cropToMusic(
        preprocessedPages[i],
        pageIndex: i,
        pageCount: preprocessedPages.length,
      );
      if (cropped == null) return null; // cancelling any page's crop cancels the whole scan
      croppedPages.add(cropped);
    }

    return OmrOrchestrator().recogniseMultiPage(
      croppedPages,
      title: title,
      onProgress: (pageIndex, stage) => onProgress?.call(switch (stage) {
        OmrStage.segmenting => OmrScanStage.segmenting,
        OmrStage.detecting => OmrScanStage.detecting,
        OmrStage.recognising => OmrScanStage.recognising,
        OmrStage.assembling => OmrScanStage.assembling,
      }),
    );
  }

  /// Acquire the raw page-image bytes (JPEG or PNG), one entry per page, in
  /// page order, from the chosen [source]. Returns null if the user cancels
  /// the picker. `preprocessImage` decodes either format, so no conversion
  /// is needed here.
  Future<List<Uint8List>?> _acquire(OmrImageSource source) async {
    switch (source) {
      case OmrImageSource.camera:
        return _acquireFromCamera();
      case OmrImageSource.photoLibrary:
        return _acquireFromPhotos();
      case OmrImageSource.file:
        return _acquireFromFile();
    }
  }

  Future<List<Uint8List>?> _acquireFromCamera() async {
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

    final pages = <Uint8List>[];
    for (final path in result.images) {
      pages.add(await (await _resolveToFile(path)).readAsBytes());
    }
    return pages;
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

  Future<List<Uint8List>?> _acquireFromPhotos() async {
    // pickMultiImage() signals cancel with an empty list, never null — unlike
    // pickImage(), which this replaces.
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty) return null;

    final pages = <Uint8List>[];
    for (final file in picked) {
      pages.add(await file.readAsBytes());
    }
    return pages;
  }

  Future<List<Uint8List>?> _acquireFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
      allowMultiple: true,
    );
    final files = result?.files;
    if (files == null || files.isEmpty) return null;

    final pages = <Uint8List>[];
    for (final file in files) {
      final bytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) continue; // unreadable entry — skip rather than abort the whole selection

      final isPdf = (file.extension ?? '').toLowerCase() == 'pdf';
      if (isPdf) {
        pages.addAll(await _rasterizeAllPdfPages(bytes));
      } else {
        pages.add(bytes);
      }
    }
    if (pages.isEmpty) return null;
    return pages;
  }

  /// Render every page of a PDF to PNG bytes for the OMR pipeline, in
  /// document order. Renders at [_pdfTargetWidth] px wide to match
  /// `preprocessImage`'s own resize target.
  static const _pdfTargetWidth = 1920.0;

  Future<List<Uint8List>> _rasterizeAllPdfPages(Uint8List pdfBytes) async {
    final document = await PdfDocument.openData(pdfBytes);
    try {
      final rendered = <Uint8List>[];
      for (var pageNum = 1; pageNum <= document.pagesCount; pageNum++) { // pdfx is 1-based
        final page = await document.getPage(pageNum);
        try {
          final scale = _pdfTargetWidth / page.width;
          final result = await page.render(
            width: _pdfTargetWidth,
            height: page.height * scale,
            format: PdfPageImageFormat.png,
            backgroundColor: '#FFFFFF',
          );
          if (result != null) rendered.add(result.bytes);
        } finally {
          await page.close();
        }
      }
      return rendered;
    } finally {
      await document.close();
    }
  }

  Future<Uint8List?> _cropToMusic(
    Uint8List thresholdedPng, {
    required int pageIndex,
    required int pageCount,
  }) async {
    final dir = await getTemporaryDirectory();
    final source = File(
      '${dir.path}/omr_threshold_${DateTime.now().millisecondsSinceEpoch}_$pageIndex.png',
    );
    await source.writeAsBytes(thresholdedPng);

    final title = pageCount > 1 ? 'Crop to Music — Page ${pageIndex + 1} of $pageCount' : 'Crop to Music';

    final cropped = await ImageCropper().cropImage(
      sourcePath: source.path,
      uiSettings: [
        IOSUiSettings(
          title: title,
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

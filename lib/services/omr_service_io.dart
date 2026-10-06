import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:homr_flutter/homr_flutter.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import 'omr_service_base.dart';

/// Mobile/desktop scan-to-MusicXML pipeline: acquire every page's image
/// (document scanner, photo library, or file/PDF) → crop each page to the
/// music region, in colour at full resolution → `homr_flutter` recognition
/// (resize to 1920 + CLAHE inside), concatenated across pages into one piece.
class OmrService implements OmrServiceBase {
  static const _contentResolverChannel = MethodChannel('dev.homr/content_resolver');

  /// homr's models, bundled with the app by scripts/fetch_omr_models.sh.
  static final _models = OmrModels.inAssetDir('assets/omr_models');

  @override
  Future<String?> scan({
    OmrImageSource source = OmrImageSource.camera,
    void Function(OmrScanStage stage)? onProgress,
    void Function(List<ScanSourcePage> pages)? onSourcePages,
    String title = '',
  }) async {
    onProgress?.call(OmrScanStage.capturing);
    final pages = await _acquire(source);
    if (pages == null || pages.isEmpty) return null;

    // No preprocessing before the crop, and no binarization after it: the
    // user crops the page as acquired, at full resolution, and that colour
    // crop is the recogniser's input. OmrOrchestrator resizes it to 1920 px
    // wide and applies CLAHE, exactly as Python homr does. Both earlier steps
    // were harmful: resizing the WHOLE page to 1920 before cropping left a
    // half-page crop at 960 px, half the scale homr expects, and a fixed
    // threshold at 128 erased the grey staff lines of a photographed page
    // ("I Love the Mountains", Oct 2026). See
    // homr_flutter/integration_test/threshold_strategy_test.dart.
    onProgress?.call(OmrScanStage.cropping);
    final croppedPages = <Uint8List>[];
    for (var i = 0; i < pages.length; i++) {
      final cropped = await _cropToMusic(
        pages[i],
        pageIndex: i,
        pageCount: pages.length,
      );
      if (cropped == null) return null; // cancelling any page's crop cancels the whole scan
      croppedPages.add(cropped);
    }
    onSourcePages?.call([
      for (var i = 0; i < pages.length; i++)
        ScanSourcePage(original: pages[i], cropped: croppedPages[i]),
    ]);

    return OmrOrchestrator(models: _models).recogniseMultiPage(
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
  /// the picker. The cropper and the recogniser both decode either format,
  /// so no conversion is needed here.
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
  /// document order. Renders at [_pdfTargetWidth] px wide — twice homr's 1920,
  /// so that a crop of half the page still reaches the recogniser at full
  /// scale rather than being upscaled from too few pixels.
  static const _pdfTargetWidth = 3840.0;

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
    Uint8List pageBytes, {
    required int pageIndex,
    required int pageCount,
  }) async {
    final dir = await getTemporaryDirectory();
    // The page as acquired: JPEG from the camera or photo library, PNG from a
    // PDF render. Named by content so the cropper decodes it as what it is.
    final isPng = pageBytes.length > 3 && pageBytes[0] == 0x89 && pageBytes[1] == 0x50;
    final source = File(
      '${dir.path}/omr_page_${DateTime.now().millisecondsSinceEpoch}_$pageIndex.${isPng ? 'png' : 'jpg'}',
    );
    await source.writeAsBytes(pageBytes);

    final title = pageCount > 1 ? 'Crop to Music — Page ${pageIndex + 1} of $pageCount' : 'Crop to Music';

    final cropped = await ImageCropper().cropImage(
      sourcePath: source.path,
      // Lossless: this is the recogniser's input, and JPEG ringing around
      // thin staff lines is exactly what a threshold has to see through.
      compressFormat: ImageCompressFormat.png,
      // Caps a crop from a 48 MP photo; still at least twice the 1920 the
      // orchestrator resizes to.
      maxWidth: 4000,
      maxHeight: 4000,
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

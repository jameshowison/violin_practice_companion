import 'omr_service_base.dart';

/// Web stub. `flutter_doc_scanner` and `flutter_onnxruntime` (used by
/// `homr_omr`) are mobile/desktop only, so OMR is unavailable on web.
///
/// The planned web path is a server-side `homr` (Python) backend reachable
/// from a laptop camera capture — not yet built.
class OmrService implements OmrServiceBase {
  @override
  Future<String?> scan({
    OmrImageSource source = OmrImageSource.camera,
    void Function(OmrScanStage stage)? onProgress,
    String title = '',
    // Accepted and ignored: scanning is unavailable here, but the parameter is
    // part of the shared contract and `scan_screen.dart` passes it
    // unconditionally. Omitting it broke the web build entirely.
    Future<int?> Function(int pageCount)? onSelectPdfPage,
  }) {
    throw UnsupportedError(
      'Scan-to-MusicXML is not available on web yet. '
      'It requires a server-side homr backend (planned, not built).',
    );
  }
}

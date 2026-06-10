import 'omr_service_base.dart';

/// Web stub. `flutter_doc_scanner` and `flutter_onnxruntime` (used by
/// `homr_omr`) are mobile/desktop only, so OMR is unavailable on web.
///
/// The planned web path is a server-side `homr` (Python) backend reachable
/// from a laptop camera capture — not yet built.
class OmrService implements OmrServiceBase {
  @override
  Future<String?> scan({
    void Function(OmrScanStage stage)? onProgress,
    String title = '',
  }) {
    throw UnsupportedError(
      'Scan-to-MusicXML is not available on web yet. '
      'It requires a server-side homr backend (planned, not built).',
    );
  }
}

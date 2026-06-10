/// Stages reported via [OmrServiceBase.scan]'s `onProgress` callback, in
/// order. Capture/preprocess/crop happen on-device before handing the
/// binarized image to the `homr_omr` recognition pipeline.
enum OmrScanStage {
  capturing,
  preprocessing,
  cropping,
  segmenting,
  detecting,
  recognising,
  assembling,
}

/// Scans a page of printed sheet music and recognises it as MusicXML.
///
/// Mobile/desktop ([OmrService] in `omr_service_io.dart`) drives a real
/// document scanner + on-device OMR pipeline. Web (`omr_service_web.dart`)
/// is a stub pending a server-side `homr` backend.
abstract class OmrServiceBase {
  /// Returns the recognised MusicXML, or `null` if the user cancels at any
  /// step (scanning or cropping). [title] is embedded as the MusicXML
  /// work-title.
  Future<String?> scan({
    void Function(OmrScanStage stage)? onProgress,
    String title = '',
  });
}

/// Where the page image comes from before the OMR pipeline runs.
/// [camera] drives the live document scanner; [photoLibrary] picks an existing
/// photo; [file] picks an image or PDF from the file system.
enum OmrImageSource { camera, photoLibrary, file }

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
  /// step (acquiring the image or cropping). [source] selects where the page
  /// image comes from. [title] is embedded as the MusicXML work-title.
  ///
  /// [onSelectPdfPage] is consulted when [source] is [OmrImageSource.file] and
  /// the chosen file is a multi-page PDF: it receives the page count and returns
  /// the 0-based page to recognise, or null to cancel. Callers pass it
  /// unconditionally, so it belongs on this shared contract — every
  /// implementation must accept it, even one that can't use it.
  Future<String?> scan({
    OmrImageSource source = OmrImageSource.camera,
    void Function(OmrScanStage stage)? onProgress,
    String title = '',
    Future<int?> Function(int pageCount)? onSelectPdfPage,
  });
}

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
  Future<String?> scan({
    OmrImageSource source = OmrImageSource.camera,
    void Function(OmrScanStage stage)? onProgress,
    String title = '',
  });
}

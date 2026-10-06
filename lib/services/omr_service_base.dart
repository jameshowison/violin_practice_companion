import 'dart:typed_data';

/// Where the page image comes from before the OMR pipeline runs.
/// [camera] drives the live document scanner; [photoLibrary] picks an existing
/// photo; [file] picks an image or PDF from the file system.
enum OmrImageSource { camera, photoLibrary, file }

/// Stages reported via [OmrServiceBase.scan]'s `onProgress` callback, in
/// order. Capture and crop happen on-device before handing the colour crop to
/// the `homr_flutter` recognition pipeline (which resizes it and applies CLAHE).
enum OmrScanStage {
  capturing,
  cropping,
  segmenting,
  detecting,
  recognising,
  assembling,
}

/// One page as it went into recognition: the image as acquired, and the
/// user's colour crop of it — the exact input the OMR pipeline received. Kept so a bad scan can be diagnosed afterwards; see
/// `ScanSourceStore`.
class ScanSourcePage {
  final Uint8List original;
  final Uint8List cropped;
  const ScanSourcePage({required this.original, required this.cropped});
}

/// Scans one or more pages of printed sheet music and recognises them as a
/// single MusicXML piece.
///
/// Mobile/desktop ([OmrService] in `omr_service_io.dart`) drives a real
/// document scanner + on-device OMR pipeline. Web (`omr_service_web.dart`)
/// is a stub pending a server-side `homr` backend.
abstract class OmrServiceBase {
  /// Returns the recognised MusicXML, or `null` if the user cancels at any
  /// step (acquiring the pages or cropping any of them). [source] selects
  /// where the pages come from. [title] is embedded as the MusicXML
  /// work-title.
  ///
  /// Multi-page sources — a scanned multi-page document, several
  /// photo-library selections, or a multi-page PDF — are all imported as one
  /// piece: every page is acquired, cropped, and recognised in order, then
  /// concatenated into a single continuous MusicXML result.
  ///
  /// [onSourcePages] receives every page's source images once the last crop
  /// is done, before recognition starts, so the caller can keep what a
  /// nonsense result was recognised from.
  Future<String?> scan({
    OmrImageSource source = OmrImageSource.camera,
    void Function(OmrScanStage stage)? onProgress,
    void Function(List<ScanSourcePage> pages)? onSourcePages,
    String title = '',
  });
}

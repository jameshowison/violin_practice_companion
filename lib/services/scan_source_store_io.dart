import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'omr_service_base.dart';

/// Keeps the images a scanned piece was recognised from, so a bad scan can be
/// diagnosed after the fact — which crop did OMR actually see?
///
/// `scan_sources/<pieceId>/page_<n>_original.<ext>` is the page as acquired
/// (camera, photo or PDF render) and `page_<n>_crop.<ext>` is the colour crop
/// the user drew, i.e. exactly the recogniser's input. Before this, the
/// only copy of a crop was image_cropper's file in the temp directory, which
/// iOS empties whenever it likes.
///
/// The folder is part of the dev-library sync (`dev_library_io.dart`), so the
/// sources of a scan made on any dev device come back to the Mac.
class ScanSourceStore {
  ScanSourceStore({Directory? root}) : _root = root;

  Directory? _root;

  static const folder = 'scan_sources';

  Future<Directory> _dir(String pieceId) async {
    final docs = _root ??= await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$folder/$pieceId');
  }

  Future<void> save(String pieceId, List<ScanSourcePage> pages) async {
    final dir = await _dir(pieceId);
    await dir.create(recursive: true);
    for (var i = 0; i < pages.length; i++) {
      final n = i + 1;
      await _write(dir, 'page_${n}_original', pages[i].original);
      await _write(dir, 'page_${n}_crop', pages[i].cropped);
    }
  }

  /// Idempotent: a piece that was never scanned has nothing to remove.
  Future<void> delete(String pieceId) async {
    final dir = await _dir(pieceId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static Future<void> _write(Directory dir, String stem, Uint8List bytes) =>
      File('${dir.path}/$stem.${_extensionOf(bytes)}').writeAsBytes(bytes);

  /// By content rather than by where it came from: the scanner, the photo
  /// picker, the PDF renderer and image_cropper each hand back their own
  /// format.
  static String _extensionOf(Uint8List b) {
    if (b.length >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) {
      return 'png';
    }
    if (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return 'jpg';
    if (b.length >= 12 && String.fromCharCodes(b.sublist(8, 12)) == 'HEIC') return 'heic';
    return 'bin';
  }
}

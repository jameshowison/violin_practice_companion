import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'omr_service_base.dart';

/// Keeps the images a scanned piece was recognised from, so a bad scan can be
/// diagnosed after the fact — which crop did OMR actually see?
///
/// `scan_sources/<pieceId>/page_<n>_original.<ext>` is the page as acquired
/// (camera, photo or PDF render) and `page_<n>_crop.<ext>` is the colour crop
/// the user drew, the recogniser's input. Before this, the only copy of a
/// crop was image_cropper's file in the temp directory, which iOS empties
/// whenever it likes.
///
/// **Kept as high-quality JPEG** ([jpegQuality]), whatever they arrived as.
/// The cropper's lossless PNG and a PDF's render ran 4-11 MB a page — 148 MB
/// for one iPad's scans — and these are a fallback, for a rescan or for
/// markings the recogniser missed, not the recogniser's live input. A JPEG at
/// 92 keeps staff lines and pencil clean; a crop is no longer bit-exact what
/// OMR saw, but rescanning it gives the same notes. Saving writes what it is
/// given and compresses after, in a background isolate, so a scan is never
/// held up by it; [compressAll] converts what was stored before.
///
/// The folder is part of the dev-library sync (`dev_library_io.dart`), so the
/// sources of a scan made on any dev device come back to the Mac.
class ScanSourceStore {
  /// [compressInBackground]: after [save], re-encode the pages as JPEG. On
  /// in the app (see `scanSourceStoreProvider`); off by default so a test's
  /// files are exactly what it wrote.
  ScanSourceStore({Directory? root, this.compressInBackground = false})
      : _root = root;

  Directory? _root;
  final bool compressInBackground;

  static const int jpegQuality = 92;

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
    if (compressInBackground) {
      unawaited(compress(pieceId).catchError((Object e) {
        debugPrint('[scan_sources] compress $pieceId failed: $e');
      }));
    }
  }

  /// Re-encodes every page of [pieceId] that isn't already JPEG. A page that
  /// can't be decoded here (HEIC), or that JPEG would make bigger, is left.
  Future<void> compress(String pieceId) async {
    final dir = await _dir(pieceId);
    if (!await dir.exists()) return;
    final files = [
      await for (final e in dir.list())
        if (e is File && _page.hasMatch(e.uri.pathSegments.last)) e,
    ];
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      final ext = name.substring(dot + 1).toLowerCase();
      if (ext == 'jpg' || ext == 'jpeg') continue;
      final bytes = await file.readAsBytes();
      final jpeg = await Isolate.run(() => _toJpeg(bytes));
      if (jpeg == null || jpeg.length >= bytes.length) continue;
      await File('${dir.path}/${name.substring(0, dot)}.jpg').writeAsBytes(jpeg);
      await file.delete();
      debugPrint('[scan_sources] $pieceId/$name: '
          '${(bytes.length / 1e6).toStringAsFixed(1)} → '
          '${(jpeg.length / 1e6).toStringAsFixed(1)} MB');
    }
  }

  /// [compress] for every scanned piece, one page at a time.
  Future<void> compressAll() async {
    final docs = _root ??= await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/$folder');
    if (!await root.exists()) return;
    final pieces = [
      await for (final e in root.list())
        if (e is Directory) e.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ];
    for (final pieceId in pieces) {
      await compress(pieceId);
    }
  }

  static final _page = RegExp(r'^page_\d+_(original|crop)\.\w+$');

  /// Null when [bytes] isn't an image this can decode.
  static Uint8List? _toJpeg(Uint8List bytes) {
    var image = img.decodeImage(bytes);
    if (image == null) return null;
    if (image.hasAlpha) {
      // JPEG has no alpha: flatten onto white, as the page would be printed,
      // rather than letting transparent pixels come out black.
      final white = img.Image(width: image.width, height: image.height)
        ..clear(img.ColorRgb8(255, 255, 255));
      image = img.compositeImage(white, image);
    }
    return img.encodeJpg(image, quality: jpegQuality);
  }

  /// Each page's image as acquired, in page order — what the piece screen's
  /// "Original photo" shows. Empty for a piece that wasn't scanned (or was
  /// scanned before this store existed).
  Future<List<Uint8List>> originals(String pieceId) async =>
      [for (final f in await _originalFiles(pieceId)) await f.readAsBytes()];

  /// How many pages [originals] would return, without reading them.
  Future<int> originalCount(String pieceId) async =>
      (await _originalFiles(pieceId)).length;

  Future<List<File>> _originalFiles(String pieceId) async {
    final dir = await _dir(pieceId);
    if (!await dir.exists()) return const [];
    final byPage = <int, File>{};
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final m = _original.firstMatch(e.uri.pathSegments.last);
      if (m != null) byPage[int.parse(m.group(1)!)] = e;
    }
    return [for (final n in byPage.keys.toList()..sort()) byPage[n]!];
  }

  static final _original = RegExp(r'^page_(\d+)_original\.\w+$');

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

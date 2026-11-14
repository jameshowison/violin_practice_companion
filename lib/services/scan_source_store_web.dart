import 'dart:typed_data';

import 'omr_service_base.dart';

/// Web stub: the web build can't scan, so there are never sources to keep.
class ScanSourceStore {
  ScanSourceStore();

  Future<void> save(String pieceId, List<ScanSourcePage> pages) async {}

  Future<List<Uint8List>> originals(String pieceId) async => const [];

  Future<int> originalCount(String pieceId) async => 0;

  Future<void> delete(String pieceId) async {}
}

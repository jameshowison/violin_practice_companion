import '../models/piece.dart';

/// Web stub. Scanned-piece persistence relies on `dart:io` file access,
/// which isn't available on web — see `piece_storage_io.dart` for the
/// mobile/desktop implementation and `omr_service_web.dart` for the matching
/// scan-pipeline stub.
Future<List<Piece>> loadScannedPieces() async => const [];

Future<Piece> saveScannedPiece(String title, String musicXml) async {
  throw UnsupportedError('Saving scanned pieces is not supported on web yet.');
}

Future<String> readScannedMusicXml(String musicXmlFilePath) async {
  throw UnsupportedError('Reading scanned pieces is not supported on web yet.');
}

import '../models/piece.dart';

/// Web stub. Scanned-piece persistence relies on `dart:io` file access,
/// which isn't available on web — see `piece_storage_io.dart` for the
/// mobile/desktop implementation and `omr_service_web.dart` for the matching
/// scan-pipeline stub.

/// Editing requires writable file storage, which web lacks — so it's disabled
/// (the Edit button is hidden and fixtures stay read-only/asset-backed).
const bool storageSupportsEditing = false;

Future<List<Piece>> loadScannedPieces() async => const [];

Future<String?> fixtureFilePathIfExists(String id) async => null;

Future<String> writeFixtureFile(String id, String xml) async {
  throw UnsupportedError('Editing is not supported on web yet.');
}

Future<Piece> saveScannedPiece(String title, String musicXml) async {
  throw UnsupportedError('Saving scanned pieces is not supported on web yet.');
}

Future<String> readScannedMusicXml(String musicXmlFilePath) async {
  throw UnsupportedError('Reading scanned pieces is not supported on web yet.');
}

Future<void> updateScannedPieceFile(String musicXmlFilePath, String newMusicXml) async {
  throw UnsupportedError('Editing scanned pieces is not supported on web yet.');
}

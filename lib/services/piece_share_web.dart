import '../models/piece.dart';
import '../models/section.dart';
import 'piece_repository.dart';
import 'piece_share_bundle.dart';

/// Web stub: there are no files to share or receive, so the Share item never
/// appears (it is gated on this) and nothing below is reached.
const bool pieceShareSupported = false;

class PieceShareIo {
  PieceShareIo();

  Future<int> estimateBytes(List<ShareMediaChoice> choices) async => 0;

  Future<String> export({
    required String pieceId,
    required String title,
    required bool bundled,
    required String musicXml,
    required List<Section> sections,
    required List<ShareMediaChoice> choices,
  }) =>
      throw UnsupportedError('Sharing a piece is not available on the web.');

  Future<void> sweepOldExports() async {}

  Future<OpenedShare> open(String path) =>
      throw UnsupportedError('Sharing a piece is not available on the web.');

  Future<ShareImportResult?> apply(
    OpenedShare share, {
    required PieceRepository repo,
    required List<Piece> pieces,
    required Future<ShareConflictChoice?> Function(String title)
        onScoreConflict,
    DateTime? now,
  }) =>
      throw UnsupportedError('Sharing a piece is not available on the web.');

  Future<void> discardIncoming(String path) async {}
}

class OpenedShare {
  OpenedShare._();
  PieceShareManifest get manifest => throw UnsupportedError('web');
  Future<void> dispose() async {}
}

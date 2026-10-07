/// Web stub: there's no documents directory to keep the ABC in, so an import
/// on web keeps only its MusicXML, as every import did before this store.
class AbcSourceStore {
  AbcSourceStore();

  Future<void> save(String pieceId, String abc) async {}

  Future<String?> read(String pieceId) async => null;

  Future<void> delete(String pieceId) async {}
}

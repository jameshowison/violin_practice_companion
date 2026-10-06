/// Web stub: there is nowhere to push a library to, so there is never one to
/// ingest. Same constructor as the io version so callers needn't branch.
class DevLibraryIngester {
  DevLibraryIngester();

  Future<Object?> ingest() async => null;
}

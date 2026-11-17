// Bundled assets have no file path on the web. See bundled_asset_path_io.dart.
export 'bundled_asset_path_io.dart' if (dart.library.html) 'bundled_asset_path_web.dart';

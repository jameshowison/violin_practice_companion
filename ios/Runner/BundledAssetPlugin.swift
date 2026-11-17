import Flutter
import UIKit

/// The real path of a bundled Flutter asset — see
/// `lib/services/bundled_asset_path_io.dart`.
///
/// On iOS every asset is already a plain file inside the app bundle
/// (`App.framework/flutter_assets/<key>`), so a plugin that wants a path can
/// read it in place. Without this, flutter_onnxruntime and flutter_midi_pro
/// each copy what they load into Library/Caches: 142 MB of OMR models stored
/// twice, and a soundfont whose stale copy was never replaced.
class BundledAssetPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "stringlings/bundled_asset", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BundledAssetPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "path", let key = call.arguments as? String else {
      result(FlutterMethodNotImplemented)
      return
    }
    let lookup = FlutterDartProject.lookupKey(forAsset: key)
    // nil when the key isn't bundled; Dart then falls back to the plugin's copy.
    result(Bundle.main.path(forResource: lookup, ofType: nil))
  }
}

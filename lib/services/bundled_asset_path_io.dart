import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

const _channel = MethodChannel('stringlings/bundled_asset');

/// A real file path for the bundled asset [assetKey], for plugins that load
/// from a path (the soundfont, the OMR models), or null when there is none —
/// then the caller falls back to the plugin's own asset loader.
///
/// iOS reads the file in place inside the app bundle: no copy at all
/// (ios/Runner/BundledAssetPlugin.swift). Android copies out of the APK once
/// per install, under a name that changes with the install
/// (BundledAssetPlugin.kt). The plugins' own `…FromAsset` loaders instead copy
/// into the cache under the asset's bare file name and reuse any file already
/// there: 142 MB of models stored twice on iOS, and a 31 MB soundfont that
/// went on being loaded after a 0.9 MB one replaced it under the same name.
Future<String?> bundledAssetPath(String assetKey) async {
  try {
    return await _channel.invokeMethod<String>('path', assetKey);
  } on MissingPluginException {
    return null; // macOS, tests: no native half
  } on PlatformException catch (e) {
    debugPrint('[bundled_asset] no path for $assetKey: $e');
    return null;
  }
}

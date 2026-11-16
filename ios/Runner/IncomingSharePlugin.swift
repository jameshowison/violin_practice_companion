import Flutter
import UIKit

/// Hands a `.stringlings` file the system opened in the app (AirDrop, Files,
/// Messages, Mail) to Dart — see `lib/services/incoming_share.dart`.
///
/// iOS copies the file into `Documents/Inbox/` (Info.plist sets
/// `LSSupportsOpeningDocumentsInPlace` to NO), so a plain path is all Dart
/// needs; no security-scoped access.
///
/// Paths are QUEUED, never pushed: a file that launches the app arrives before
/// Dart is listening. Dart drains the queue with `takePending` at startup and
/// whenever this sends `pending`.
class IncomingSharePlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private static var pending: [String] = []
  private static var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "stringlings/incoming_share", binaryMessenger: registrar.messenger())
    let instance = IncomingSharePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addSceneDelegate(instance)
    IncomingSharePlugin.channel = channel
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "takePending":
      result(IncomingSharePlugin.pending)
      IncomingSharePlugin.pending.removeAll()
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts else { return false }
    return IncomingSharePlugin.receive(contexts)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return IncomingSharePlugin.receive(URLContexts)
  }

  private static func receive(_ contexts: Set<UIOpenURLContext>) -> Bool {
    let paths = contexts.map(\.url)
      .filter { $0.isFileURL && $0.pathExtension.lowercased() == "stringlings" }
      .map(\.path)
    guard !paths.isEmpty else { return false }
    pending.append(contentsOf: paths)
    channel?.invokeMethod("pending", arguments: nil)
    return true
  }
}

import Flutter
import UIKit

/// Hands a `.stringlings` file the system opened in the app (AirDrop, Files,
/// Messages, Mail) to Dart — see `lib/services/incoming_share.dart`.
///
/// Info.plist sets `LSSupportsOpeningDocumentsInPlace` to YES: without it,
/// iOS 17+ files an AirDropped `.stringlings` in Files ▸ Downloads and Files
/// will not hand it to the app on a tap. So the URL can be the user's own file,
/// behind a security scope; `copyIn` copies it out and Dart gets a plain path.
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
      .compactMap(copyIn)
    guard !paths.isEmpty else { return false }
    pending.append(contentsOf: paths)
    channel?.invokeMethod("pending", arguments: nil)
    return true
  }

  /// Copies the opened file to `Library/Caches/<uuid>-<name>` and
  /// returns the copy's path. With opening in place on, the URL is usually the
  /// user's own file (Files ▸ Downloads, where AirDrop puts it since iOS 17),
  /// readable only inside a security scope and only until this returns — and
  /// it must never be deleted. Caches is `getTemporaryDirectory()` on iOS, so
  /// `PieceShareIo.discardIncoming` cleans the copy up after the import.
  private static func copyIn(_ url: URL) -> String? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let fm = FileManager.default
    guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dest = caches.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
    do {
      // A file still downloading from iCloud reads through a coordinator.
      var coordError: NSError?
      var copyError: Error?
      NSFileCoordinator().coordinate(
        readingItemAt: url, options: .withoutChanges, error: &coordError
      ) { readable in
        do { try fm.copyItem(at: readable, to: dest) } catch { copyError = error }
      }
      if let e = coordError ?? copyError { throw e }
      // Some routes still hand over a copy in our own Documents/Inbox; that
      // one is ours to remove (a file anywhere else is the user's).
      if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
        url.standardizedFileURL.path.hasPrefix(
          docs.appendingPathComponent("Inbox").standardizedFileURL.path + "/")
      {
        try? fm.removeItem(at: url)
      }
      NSLog("[share] copied incoming %@", url.path)
      return dest.path
    } catch {
      NSLog("[share] could not copy incoming %@: %@", url.path, "\(error)")
      return nil
    }
  }
}

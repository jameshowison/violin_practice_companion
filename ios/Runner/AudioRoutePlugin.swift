import AVFoundation
import AVKit
import Flutter
import UIKit

/// Reports where audio is going and how late it arrives there: the current
/// output port (built-in speaker, Bluetooth, AirPlay, wired…) and the session's
/// `outputLatency` + `ioBufferDuration`. Pushes a fresh report to Dart whenever
/// the route changes, so the synthesized score can move its cursor to match
/// what is actually heard. See `lib/services/audio_output.dart`.
///
/// Registered by hand from `AppDelegate`, like `AudioDecoderPlugin`: it is a
/// few lines of AVAudioSession, and `audio_session` (already a transitive
/// dependency via just_audio) exposes the route but not its latency.
public class AudioRoutePlugin: NSObject, FlutterPlugin {
  private static let channelName = "violin_practice_companion/audio_route"
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = AudioRoutePlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    NotificationCenter.default.addObserver(
      instance, selector: #selector(routeChanged(_:)),
      name: AVAudioSession.routeChangeNotification, object: nil)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getRoute":
      result(Self.describe())
    case "showPicker":
      DispatchQueue.main.async { [weak self] in
        result(self?.showPicker() ?? false)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// One hidden system route picker, kept for the app's life. The button the
  /// user sees is Flutter's (so it matches the transport and Marionette can
  /// find it); tapping it presses this picker's own button, which presents the
  /// standard speaker / Bluetooth / AirPlay sheet. The resulting route change
  /// arrives through [routeChanged] like any other.
  private var picker: AVRoutePickerView?

  private func showPicker() -> Bool {
    if picker == nil {
      let window = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
      guard let root = window?.rootViewController?.view else { return false }
      // Not isHidden and not zero-sized: iOS presents nothing from a picker
      // that isn't on screen. Nearly transparent, untouchable, in a corner.
      let p = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
      p.prioritizesVideoDevices = false
      p.alpha = 0.011
      p.isUserInteractionEnabled = false
      root.addSubview(p)
      picker = p
    }
    guard let button = picker?.subviews.compactMap({ $0 as? UIButton }).first
    else { return false }
    button.sendActions(for: .touchUpInside)
    return true
  }

  @objc private func routeChanged(_ notification: Notification) {
    // The notification arrives on an arbitrary thread, and outputLatency can
    // still read the OLD port's value at that instant — so report now (the
    // port name is right) and again once the new route has settled.
    for delay in [0.0, 0.5] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.channel.invokeMethod("routeChanged", arguments: Self.describe())
      }
    }
  }

  private static func describe() -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    let output = session.currentRoute.outputs.first
    return [
      "outputLatency": session.outputLatency,
      "ioBufferDuration": session.ioBufferDuration,
      "portName": output?.portName ?? "",
      "portType": output?.portType.rawValue ?? "",
      "uid": output?.uid ?? "",
    ]
  }
}

import AVFoundation
import Flutter

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
    guard call.method == "getRoute" else {
      result(FlutterMethodNotImplemented)
      return
    }
    result(Self.describe())
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

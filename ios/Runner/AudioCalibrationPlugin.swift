import AVFoundation
import Flutter

/// Mic capture for the speaker sync calibration (`lib/services/sync_calibrator.dart`).
///
/// The app runs in play-and-record throughout ([applyAppSession]), so
/// `start` only prefers the built-in mic and starts listening, and `stop`
/// stops and returns the energy envelope of what was heard (high-passed, 1ms
/// slices) with the wall-clock time of its first slice.
///
/// The timestamps are the point: the input tap's host time, converted to the
/// same clock as Dart's `DateTime.now()`, less the session's input latency —
/// so the moment a click reached the mic can be compared with the moment the
/// Dart-side player reached it. The `record` package gives samples but no
/// such time, which is why this exists.
public class AudioCalibrationPlugin: NSObject, FlutterPlugin {
  private static let channelName = "violin_practice_companion/audio_calibration"

  private var engine: AVAudioEngine?

  // Written on the audio thread, read on stop — under [lock].
  private let lock = NSLock()
  private var envelope: [Float] = []
  private var startWall: Double?
  private var hostTimeValid = false
  private var firstHostSec: Double = 0
  private var lastHostSec: Double = 0
  private var framesBeforeLast = 0
  private var framesSeen = 0
  private var hopFrames = 48
  private var sampleRate: Double = 48000
  private var inputLatency: Double = 0
  private var acc: Float = 0
  private var accN = 0
  private var prev: Float = 0

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = AudioCalibrationPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async {
          guard granted else {
            result(FlutterError(
              code: "permission", message: "Microphone access is off", details: nil))
            return
          }
          do {
            result(try self.start())
          } catch {
            self.teardown()
            result(FlutterError(
              code: "start", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "stop":
      result(stop())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The session the whole app runs in, set at launch (AppDelegate) and
  /// left alone: play-and-record, though the mic only runs while
  /// calibrating. Switching between .playback and play-and-record around
  /// each calibration broke playback afterwards three different ways — the
  /// synth went silent, the recording player went silent, an AirPlay speaker
  /// came back muted until a volume press. With no switch, calibrating only
  /// starts and stops the mic, and measures the very setup that plays.
  ///
  /// A2DP but not plain Bluetooth, so a Bluetooth speaker is never dropped
  /// into its call (HFP) profile; AirPlay allowed, else it is moved to the
  /// built-in speaker; built-in speaker rather than the iPhone's receiver.
  /// Not silenced by the ringer switch, as .playback wasn't.
  static let appCategory = AVAudioSession.Category.playAndRecord
  static let appMode = AVAudioSession.Mode.default
  static let appOptions: AVAudioSession.CategoryOptions = [
    .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker,
  ]

  /// Applies the app's session; true if it wasn't already in place (the
  /// teacher-demo recorder sets its own).
  @discardableResult
  static func applyAppSession() -> Bool {
    let s = AVAudioSession.sharedInstance()
    if s.category == appCategory && s.mode == appMode && s.categoryOptions == appOptions {
      return false
    }
    try? s.setCategory(appCategory, mode: appMode, options: appOptions)
    return true
  }

  private var sessionChanged = false

  private func start() throws -> [String: Any] {
    teardown()
    let s = AVAudioSession.sharedInstance()
    let before = s.currentRoute.outputs.first
    sessionChanged = Self.applyAppSession()
    // The built-in mic is chosen BEFORE activating: if iOS ever picks the
    // speaker's own mic, a Bluetooth speaker has to drop to its call (HFP)
    // profile to serve it, and the output goes with it.
    if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
      try? s.setPreferredInput(mic)
    }
    try s.setActive(true)
    if s.currentRoute.inputs.first?.portType != .builtInMic,
      let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic })
    {
      try? s.setPreferredInput(mic)
    }

    let e = AVAudioEngine()
    let input = e.inputNode
    let fmt = input.outputFormat(forBus: 0)
    guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
      throw NSError(
        domain: "AudioCalibration", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
    }

    lock.lock()
    envelope = []
    envelope.reserveCapacity(12000)
    startWall = nil
    framesSeen = 0
    acc = 0
    accN = 0
    prev = 0
    sampleRate = fmt.sampleRate
    hopFrames = max(1, Int((fmt.sampleRate / 1000).rounded()))
    inputLatency = s.inputLatency
    lock.unlock()

    input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, when in
      self?.consume(buf, when)
    }
    try e.start()
    engine = e

    let after = s.currentRoute
    return [
      "outputBefore": before?.portType.rawValue ?? "",
      "outputAfter": after.outputs.first?.portType.rawValue ?? "",
      "outputName": after.outputs.first?.portName ?? "",
      "input": after.inputs.first?.portName ?? "",
      "sampleRate": fmt.sampleRate,
      "inputLatency": s.inputLatency,
      "outputLatency": s.outputLatency,
    ]
  }

  private func consume(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime) {
    guard let ch = buf.floatChannelData?[0] else { return }
    let n = Int(buf.frameLength)
    lock.lock()
    defer { lock.unlock() }
    if startWall == nil {
      hostTimeValid = when.isHostTimeValid
      let nowWall = Date().timeIntervalSince1970
      if when.isHostTimeValid {
        let nowHost = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        firstHostSec = AVAudioTime.seconds(forHostTime: when.hostTime)
        startWall = nowWall - (nowHost - firstHostSec) - inputLatency
      } else {
        startWall = nowWall - Double(n) / sampleRate - inputLatency
      }
    }
    if when.isHostTimeValid {
      lastHostSec = AVAudioTime.seconds(forHostTime: when.hostTime)
      framesBeforeLast = framesSeen
    }
    for i in 0..<n {
      let x = ch[i]
      let d = x - prev
      prev = x
      acc += d * d
      accN += 1
      if accN == hopFrames {
        envelope.append(acc / Float(hopFrames))
        acc = 0
        accN = 0
      }
    }
    framesSeen += n
  }


  private func stop() -> [String: Any] {
    teardown()
    lock.lock()
    defer { lock.unlock() }
    // How far the sample count and the host clock disagreed over the capture:
    // the slices are placed by count, so this is the timing error at the end.
    let drift = hostTimeValid
      ? (lastHostSec - firstHostSec) - Double(framesBeforeLast) / sampleRate : 0
    let data = envelope.withUnsafeBufferPointer { Data(buffer: $0) }
    return [
      "startWall": startWall ?? 0,
      "hop": Double(hopFrames) / sampleRate,
      "energy": FlutterStandardTypedData(float32: data),
      "hostTimeValid": hostTimeValid,
      "driftSeconds": drift,
      "inputLatency": inputLatency,
      "sessionChanged": sessionChanged,
    ]
  }

  private func teardown() {
    if let e = engine {
      e.inputNode.removeTap(onBus: 0)
      e.stop()
      engine = nil
    }
  }
}

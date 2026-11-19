import AVFoundation
import Flutter
import UIKit

/// Plays a medium that is a video WITH its sound in one AVPlayer: the sound to
/// the current output, the picture into a Flutter texture. Dart drives it as
/// the recording's transport (lib/services/media_transport_io.dart), in place
/// of just_audio playing the sound beside video_player playing the picture.
///
/// Why one player: an AirPlay speaker is a non-mixable route — it takes one
/// audio stream at a time. With two AVPlayers on the same file (the second
/// muted only by volume 0, which is still a stream), the speaker took the
/// sound and the picture player waited for it: on Hazel iPad with a Sonos the
/// video never moved (2026-11-18). One player is also how AVFoundation keeps
/// a picture in step with a route's own delay, which the two-player version
/// imitated with corrective seeks.
///
/// The picture stays on the device (`allowsExternalPlayback = false`); sending
/// it to an Apple TV is future work. The audio session is the app's own
/// (AudioCalibrationPlugin.applyAppSession) and is not touched here.
///
/// Audio-only recordings and the calibration's click clip play through it too
/// (`picture: false`), so every recording, and the calibration that measures
/// its delay, reads the same clock. AVPlayer's `currentTime` already allows for
/// the delay the route reports (the uncalibrated default adds nothing); what
/// the calibration measures is only what that allowance gets wrong.
///
/// Channel `vpc/video_transport` — create {path, picture} → {id, textureId
/// (-1 without a picture), durationMs, width, height, rotation}; play {id,
/// rate}; pause {id}; seek {id, ms}; setRate {id, rate}; setEnd {id, ms|null};
/// clock {id} → {positionUs, rate, wallUs}; dispose {id}.
/// Events on `vpc/video_transport/events`: {id, positionUs, rate, completed,
/// wallUs} whenever the timeline changes, and twice a second while it runs,
/// so Dart can extrapolate the position between them. `wallUs` is the Unix
/// wall clock in microseconds, read at the same moment as the position — the
/// clock Dart's DateTime.now() and the calibration mic's stamps are on.
public class VideoTransportPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let textures: FlutterTextureRegistry
  private var players: [Int: VideoTransport] = [:]
  private var nextId = 1
  private var sink: FlutterEventSink?

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VideoTransportPlugin(textures: registrar.textures())
    let channel = FlutterMethodChannel(
      name: "vpc/video_transport", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(
      name: "vpc/video_transport/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  fileprivate func emit(_ event: [String: Any]) {
    if Thread.isMainThread {
      sink?(event)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?(event) }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "create" {
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "args", message: "path missing", details: nil))
        return
      }
      let id = nextId
      nextId += 1
      let transport = VideoTransport(id: id, url: URL(fileURLWithPath: path),
                                     picture: args["picture"] as? Bool ?? true,
                                     textures: textures, plugin: self)
      players[id] = transport
      transport.load { [weak self] info, error in
        if let error = error {
          self?.players[id]?.dispose()
          self?.players[id] = nil
          result(FlutterError(code: "load", message: error, details: nil))
        } else {
          result(info)
        }
      }
      return
    }
    guard let id = args["id"] as? Int, let transport = players[id] else {
      result(FlutterError(code: "id", message: "no such player", details: nil))
      return
    }
    switch call.method {
    case "play":
      transport.play(rate: Float(args["rate"] as? Double ?? 1))
      result(nil)
    case "pause":
      transport.pause()
      result(nil)
    case "setRate":
      transport.setRate(Float(args["rate"] as? Double ?? 1))
      result(nil)
    case "seek":
      transport.seek(ms: args["ms"] as? Int ?? 0) { result(nil) }
    case "setEnd":
      transport.setEnd(ms: args["ms"] as? Int)
      result(nil)
    case "clock":
      result(transport.clock())
    case "dispose":
      transport.dispose()
      players[id] = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// One loaded file: its AVPlayer, the video output feeding the texture, and
/// the display link that pulls frames from it.
private class VideoTransport: NSObject, FlutterTexture {
  let id: Int
  private let url: URL
  private let wantsPicture: Bool
  private let textures: FlutterTextureRegistry
  private weak var plugin: VideoTransportPlugin?

  private let player = AVPlayer()
  private var item: AVPlayerItem?
  private var output: AVPlayerItemVideoOutput?
  private var textureId: Int64 = -1
  private var displayLink: CADisplayLink?
  private var latest: CVPixelBuffer?
  private var observations: [NSKeyValueObservation] = []
  private var endObserver: NSObjectProtocol?
  private var tokens: [NSObjectProtocol] = []
  private var lastTraced = 0.0
  private var heartbeat: Timer?

  /// The rate Play asked for; AVPlayer's own `rate` is 0 when paused.
  private var wantedRate: Float = 1
  private var playing = false
  private var completed = false

  /// Seeks still in flight. A Play sent while one is — Play from the
  /// selection's start, just after the last run stopped at its end — must wait
  /// for it: AVPlayer starts at once from where it is, which is still the end,
  /// posts "played to end" on the spot, and Dart took that for this run's end
  /// and stopped it (the first Play after a stop did nothing, the second
  /// worked; dev-iphone-se, 2026-11-18).
  private var pendingSeeks = 0
  private var playAfterSeek = false

  init(id: Int, url: URL, picture: Bool, textures: FlutterTextureRegistry,
       plugin: VideoTransportPlugin) {
    self.id = id
    self.url = url
    self.wantsPicture = picture
    self.textures = textures
    self.plugin = plugin
    super.init()
  }

  func load(_ done: @escaping ([String: Any]?, String?) -> Void) {
    let asset = AVURLAsset(url: url)
    Task { @MainActor in
      do {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        var size = CGSize.zero
        var rotation = 0
        if let track = tracks.first {
          let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
          size = natural
          rotation = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        }
        self.attach(AVPlayerItem(asset: asset), picture: self.wantsPicture && !tracks.isEmpty)
        done([
          "id": self.id,
          "textureId": self.textureId,
          "durationMs": duration.isNumeric ? Int(duration.seconds * 1000) : 0,
          "width": Double(size.width),
          "height": Double(size.height),
          "rotation": (rotation + 360) % 360,
        ], nil)
      } catch {
        done(nil, error.localizedDescription)
      }
    }
  }

  private func attach(_ item: AVPlayerItem, picture: Bool) {
    // Slowed down, keep the pitch — as just_audio does (UriAudioSource.m).
    item.audioTimePitchAlgorithm = .timeDomain
    self.item = item
    player.allowsExternalPlayback = false
    player.actionAtItemEnd = .pause
    if picture { attachPicture(to: item) }
    player.replaceCurrentItem(with: item)

    observations.append(player.observe(\.timeControlStatus) { [weak self] p, _ in
      let status = ["paused", "waiting", "playing"][min(p.timeControlStatus.rawValue, 2)]
      self?.trace("timeControl \(status) why=\(p.reasonForWaitingToPlay?.rawValue ?? "-")")
      self?.report()
    })
    observations.append(item.observe(\.status) { [weak self] i, _ in
      self?.trace("item status=\(i.status.rawValue) error=\(i.error?.localizedDescription ?? "-")")
    })
    let nc = NotificationCenter.default
    for name in [AVPlayerItem.playbackStalledNotification,
                 AVPlayerItem.failedToPlayToEndTimeNotification,
                 AVPlayerItem.newErrorLogEntryNotification] {
      tokens.append(nc.addObserver(forName: name, object: item, queue: .main) {
        [weak self, weak item] n in
        let err = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
          .localizedDescription ?? item?.errorLog()?.events.last?.errorComment ?? "-"
        self?.trace("\(n.name.rawValue) \(err)")
      })
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      guard let self = self, self.pendingSeeks == 0 else { return }
      self.completed = true
      self.report()
    }
    heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self = self, self.player.timeControlStatus == .playing else { return }
      self.report()
    }
  }

  private func attachPicture(to item: AVPlayerItem) {
    // As video_player: tone-map HDR to the texture's BT.709.
    let output = AVPlayerItemVideoOutput(outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ])
    item.add(output)
    self.output = output
    textureId = textures.register(self)
    let link = CADisplayLink(target: self, selector: #selector(onFrame))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func onFrame() {
    guard let output = output else { return }
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time),
          let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    else { return }
    latest = buffer
    textures.textureFrameAvailable(textureId)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let latest = latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  /// The timeline as it stands: where the item is and how fast its clock is
  /// actually running (0 while paused or waiting, whatever Play asked for).
  func clock() -> [String: Any] {
    guard let item = item else { return [:] }
    let position = item.currentTime()
    let wall = Date().timeIntervalSince1970
    var rate: Double = 0
    if let timebase = item.timebase {
      rate = CMTimebaseGetRate(timebase)
    }
    return [
      "positionUs": position.isNumeric ? Int((position.seconds * 1e6).rounded()) : 0,
      "rate": rate,
      "wallUs": Int((wall * 1e6).rounded()),
    ]
  }

  /// Into the running diagnostic trace, if any (AudioCalibrationPlugin):
  /// what this player did around a route change, with its clock.
  private func trace(_ what: String) {
    let c = clock()
    AudioCalibrationPlugin.traceEvent(
      "player\(id)",
      "\(what) pos=\((c["positionUs"] as? Int ?? 0) / 1000)ms rate=\(c["rate"] ?? 0) "
        + "playerRate=\(player.rate)")
  }

  private func report() {
    var event = clock()
    if event.isEmpty { return }
    // Every 2s while running, so a stall shows as a position that stops.
    let now = CACurrentMediaTime()
    if now - lastTraced > 2 {
      lastTraced = now
      trace("tick")
    }
    event["id"] = id
    event["completed"] = completed
    plugin?.emit(event)
  }

  func play(rate: Float) {
    wantedRate = rate
    playing = true
    completed = false
    trace("play rate=\(rate) pendingSeeks=\(pendingSeeks)")
    if pendingSeeks > 0 {
      playAfterSeek = true
      return
    }
    player.playImmediately(atRate: rate)
    report()
  }

  func pause() {
    playing = false
    playAfterSeek = false
    trace("pause")
    player.pause()
    report()
  }

  func setRate(_ rate: Float) {
    wantedRate = rate
    if playing && pendingSeeks == 0 { player.rate = rate }
    report()
  }

  func seek(ms: Int, _ done: @escaping () -> Void) {
    completed = false
    pendingSeeks += 1
    trace("seek to \(ms)ms")
    let target = CMTime(value: CMTimeValue(ms), timescale: 1000)
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return done() }
        self.pendingSeeks -= 1
        if self.pendingSeeks == 0 && self.playAfterSeek {
          self.playAfterSeek = false
          if self.playing { self.player.playImmediately(atRate: self.wantedRate) }
        }
        self.report()
        done()
      }
    }
  }

  /// Where the item stops by itself — the selection's end, exactly, as
  /// just_audio's ClippingAudioSource gives (AVPlayerItem's
  /// forwardPlaybackEndTime in both).
  func setEnd(ms: Int?) {
    item?.forwardPlaybackEndTime =
      ms.map { CMTime(value: CMTimeValue($0), timescale: 1000) } ?? .invalid
  }

  func dispose() {
    heartbeat?.invalidate()
    displayLink?.invalidate()
    displayLink = nil
    observations.forEach { $0.invalidate() }
    observations = []
    if let endObserver = endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    tokens.forEach { NotificationCenter.default.removeObserver($0) }
    tokens = []
    player.pause()
    player.replaceCurrentItem(with: nil)
    if textureId >= 0 { textures.unregisterTexture(textureId) }
    latest = nil
  }
}

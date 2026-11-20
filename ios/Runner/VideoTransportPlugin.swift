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
    case "seekFresh":
      transport.seekFresh(ms: args["ms"] as? Int ?? 0) { result(nil) }
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

  /// Replaced only by [rebuildPlayer], when an item fails twice in one Play.
  private var player = AVPlayer()
  private var item: AVPlayerItem?
  private var output: AVPlayerItemVideoOutput?
  private var textureId: Int64 = -1
  private var displayLink: CADisplayLink?
  private var latest: CVPixelBuffer?
  private var observations: [NSKeyValueObservation] = []
  private var endObserver: NSObjectProtocol?
  private var tokens: [NSObjectProtocol] = []
  private var itemStatus: NSKeyValueObservation?
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
  private var stalledSince: CFTimeInterval?
  private var playAfterSeek = false
  /// How far [itemFailed] has got in this Play: 0 none, 1 retried on a fresh
  /// item, 2 rebuilt the player. A third failure gives up ([failed]).
  private var failStep = 0
  /// Gave up on this Play: reported to Dart, which stops and offers the
  /// speaker picker. Cleared by the next Play.
  private var failed = false

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
    if picture { attachPicture(to: item) }
    setUpPlayer()
    player.replaceCurrentItem(with: item)
    observeItem(item)
    heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self = self, self.player.timeControlStatus == .playing else {
        self?.stalledSince = nil
        return
      }
      self.unwedge()
      self.report()
    }
  }

  /// The player's settings and its own observer; again for a rebuilt one.
  private func setUpPlayer() {
    player.allowsExternalPlayback = false
    player.actionAtItemEnd = .pause
    observations.forEach { $0.invalidate() }
    observations = [player.observe(\.timeControlStatus) { [weak self] p, _ in
      guard let self = self, p === self.player else { return }
      let status = ["paused", "waiting", "playing"][min(p.timeControlStatus.rawValue, 2)]
      self.trace("timeControl \(status) why=\(p.reasonForWaitingToPlay?.rawValue ?? "-")")
      self.report()
    }]
  }

  /// A new AVPlayer in place of this one, then a fresh item at [ms]: the
  /// nearest the app can come to the user switching the speaker away and
  /// back, which is what revived a stale AirPlay connection by hand. Apple
  /// gives an app no way to reconnect a route itself.
  private func rebuildPlayer(ms: Int) {
    trace("rebuilding the player")
    let old = player
    old.pause()
    old.replaceCurrentItem(with: nil)
    player = AVPlayer()
    setUpPlayer()
    playAfterSeek = true
    seekFresh(ms: ms) {}
  }

  /// The item's own observers: status, stalls and errors for the trace, and
  /// its end. Per item, so a fresh item ([seekFresh]) gets its own.
  private func observeItem(_ item: AVPlayerItem) {
    itemStatus?.invalidate()
    tokens.forEach { NotificationCenter.default.removeObserver($0) }
    tokens = []
    if let endObserver = endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    itemStatus = item.observe(\.status) { [weak self] i, _ in
      self?.trace("item status=\(i.status.rawValue) error=\(i.error?.localizedDescription ?? "-")")
    }
    let nc = NotificationCenter.default
    tokens.append(nc.addObserver(
      forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] n in
      self?.itemFailed(n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
    })
    for name in [AVPlayerItem.playbackStalledNotification,
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
  }

  /// Seeks a FRESH copy of the item to [ms], in place of the one playing,
  /// and plays it if Play is in force. For every start after the item has
  /// played to its end — a loop going round, Play again after a stop at the
  /// selection's end. On AirPlay, seeking the ended item and playing at once
  /// left AVPlayer "playing" with its clock stopped for ~10 s, on every
  /// third pass or so, for a recording and the rendered score alike (Jamz +
  /// Kitchen, 2026-11-19); a start after a settled pause never did. The
  /// player, and with it the AirPlay stream, stays; only the item is new.
  /// A short gap at a loop's seam is the price.
  func seekFresh(ms: Int, _ done: @escaping () -> Void) {
    guard let old = item else { return done() }
    trace("fresh item at \(ms)ms")
    let fresh = AVPlayerItem(asset: old.asset)
    fresh.audioTimePitchAlgorithm = .timeDomain
    fresh.forwardPlaybackEndTime = old.forwardPlaybackEndTime
    if let output = output {
      old.remove(output)
      fresh.add(output)
    }
    completed = false
    pendingSeeks += 1
    item = fresh
    observeItem(fresh)
    player.replaceCurrentItem(with: fresh)
    // An item can't take a seek until it is ready to play.
    var ready: NSKeyValueObservation?
    var fired = false
    ready = fresh.observe(\.status, options: [.initial, .new]) { [weak self] i, _ in
      guard i.status != .unknown, !fired else { return }
      fired = true
      ready?.invalidate()
      ready = nil
      DispatchQueue.main.async {
        guard let self = self else { return done() }
        let target = CMTime(value: CMTimeValue(ms), timescale: 1000)
        self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
          DispatchQueue.main.async {
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
    event["failed"] = failed
    plugin?.emit(event)
  }

  /// Seen on AirPlay after overlapping seeks, plays and pauses (a loop that
  /// restarted twice, Jamz + Kitchen, 2026-11-19): timeControlStatus said
  /// playing while the item's clock stood still, for good — through the next
  /// Play from the same spot too; only a seek somewhere else freed it. So a
  /// clock that hasn't moved for 1.5 s of "playing" is sought 50 ms back —
  /// not to where it is, which was the seek that didn't free it — and
  /// started again. (A healthy start runs within ~50 ms, AirPlay included.)
  private func unwedge() {
    guard playing, pendingSeeks == 0, !completed,
      let timebase = item?.timebase, CMTimebaseGetRate(timebase) == 0
    else {
      stalledSince = nil
      return
    }
    let now = CACurrentMediaTime()
    guard let since = stalledSince else {
      stalledSince = now
      return
    }
    guard now - since > 1.5 else { return }
    stalledSince = nil
    let at = player.currentTime()
    guard at.isNumeric else { return }
    trace("stalled while playing; re-seeking")
    let ms = max(0, Int((at.seconds * 1000).rounded()) - 50)
    playAfterSeek = true
    seekFresh(ms: ms) {}
  }

  /// The item gave up mid-play ("failed to play to end time"). Seen on Jamz +
  /// Kitchen (2026-11-20) on the first Plays after ~2 h idle, for a recording
  /// and the rendered score alike: the item failed ~50 ms after starting, with
  /// "The operation could not be completed", and every Play after it failed the
  /// same way until the speaker was switched to the phone and back — most
  /// likely a stale AirPlay connection. So the error is traced in full
  /// (domain, code, underlying error), and then, from where it stopped:
  /// 1. a fresh item ([seekFresh]);
  /// 2. a new AVPlayer ([rebuildPlayer]);
  /// 3. give up: [failed] goes to Dart, which stops and offers the speaker
  ///    picker, since re-picking the speaker is the one cure that worked.
  /// Which step (if any) wins over a stale speaker is for the trace of the
  /// next occurrence to tell; none had been seen to when this was written.
  private func itemFailed(_ error: NSError?) {
    var what = "-"
    if let e = error {
      what = "\(e.domain) \(e.code) \(e.localizedDescription)"
      if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
        what += " <- \(u.domain) \(u.code) \(u.localizedDescription)"
      }
    }
    if let ev = item?.errorLog()?.events.last {
      what += " log: \(ev.errorDomain) \(ev.errorStatusCode) \(ev.errorComment ?? "-")"
    }
    trace("item failed: \(what)")
    guard playing else { return }
    let at = player.currentTime()
    let ms = at.isNumeric ? max(0, Int((at.seconds * 1000).rounded())) : 0
    failStep += 1
    switch failStep {
    case 1:
      trace("retrying on a fresh item")
      playAfterSeek = true
      seekFresh(ms: ms) {}
    case 2:
      rebuildPlayer(ms: ms)
    default:
      trace("giving up: the speaker isn't answering")
      playing = false
      playAfterSeek = false
      failed = true
      player.pause()
      report()
    }
  }

  func play(rate: Float) {
    wantedRate = rate
    playing = true
    completed = false
    failStep = 0
    failed = false
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
    itemStatus?.invalidate()
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

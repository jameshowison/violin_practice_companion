import AVFoundation
import Flutter

/// The app's own native media helpers, on `violin_practice_companion/media_tools`
/// (lib/services/media_tools.dart): `shrinkVideo` and `encodeAac`. They once
/// shared the decoder's channel and file; the decoder is headed for a library
/// and these write files in the app's own formats, so they stay here.
///
/// Registered by hand from `AppDelegate`.
public class MediaToolsPlugin: NSObject, FlutterPlugin {
  private static let channelName = "violin_practice_companion/media_tools"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MediaToolsPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "shrinkVideo":
      handleShrinkVideo(call, result: result)
    case "encodeAac":
      handleEncodeAac(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - Shrinking imported video

/// Re-encodes an imported video's picture at a size it is actually shown at,
/// copying its audio across untouched. See `lib/services/video_shrinker_io.dart`.
///
/// Imported phone videos arrive at 1080p and 8-12 Mbps; the app shows them in
/// a toolbar-height strip or a floating window a few hundred points wide, and
/// they are most of what a piece's share bundle and the device's storage hold.
///
/// The audio is passed through (no decode, no re-encode) on purpose: it is
/// what the score-to-audio alignment was computed from and what plays, so
/// copying it leaves the cached anchors exactly right and the sound exactly as
/// it was. Re-encoding it would add a lossy generation and an encoder delay
/// that shifts every anchor by tens of milliseconds.
extension MediaToolsPlugin {
  fileprivate struct ShrinkError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  fileprivate func handleShrinkVideo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let source = arguments["source"] as? String,
      let destination = arguments["destination"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "source and destination are required", details: nil))
      return
    }
    let shortSide = (arguments["shortSide"] as? Int) ?? 720
    let bitrate = (arguments["bitrate"] as? Int) ?? 2_000_000

    // Minutes of encoding for a long video: well off the UI thread, and at a
    // priority below the decode a waiting user is watching a spinner for.
    DispatchQueue.global(qos: .utility).async {
      do {
        let outcome = try MediaToolsPlugin.shrinkVideo(
          source: source, destination: destination, shortSide: shortSide, bitrate: bitrate)
        DispatchQueue.main.async { result(outcome) }
      } catch {
        try? FileManager.default.removeItem(atPath: destination)
        DispatchQueue.main.async {
          result(FlutterError(code: "shrink_failed", message: error.localizedDescription, details: source))
        }
      }
    }
  }

  /// Returns `["skipped": reason]` when there is nothing worth doing, else
  /// `["width", "height", "codec", "bytes"]` of the new file.
  static func shrinkVideo(
    source: String, destination: String, shortSide: Int, bitrate: Int
  ) throws -> [String: Any] {
    let asset = AVURLAsset(
      url: URL(fileURLWithPath: source),
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let video = asset.tracks(withMediaType: .video).first else {
      return ["skipped": "no video track"]
    }
    let audio = asset.tracks(withMediaType: .audio).first

    // naturalSize is the encoded frame, before the rotation in
    // preferredTransform — which is carried over as-is below, so the
    // arithmetic stays in encoded orientation.
    let width = abs(video.naturalSize.width)
    let height = abs(video.naturalSize.height)
    let shortest = min(width, height)
    if shortest <= 0 { return ["skipped": "video has no size"] }
    let scale = min(1, CGFloat(shortSide) / shortest)
    if scale >= 1 && video.estimatedDataRate <= Float(bitrate) * 1.5 {
      return ["skipped": "already small"]
    }
    let even = { (v: CGFloat) -> Int in max(2, Int((v / 2).rounded()) * 2) }
    let outWidth = even(width * scale)
    let outHeight = even(height * scale)

    try? FileManager.default.removeItem(atPath: destination)
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: destination), fileType: .mp4)
    let frameRate = video.nominalFrameRate > 0 ? video.nominalFrameRate : 30

    func videoSettings(_ codec: AVVideoCodecType) -> [String: Any] {
      [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: outWidth,
        AVVideoHeightKey: outHeight,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: bitrate,
          AVVideoExpectedSourceFrameRateKey: frameRate,
          // A keyframe every second. The overlay corrects drift by seeking,
          // and a seek lands on the keyframe before it, so a long GOP makes
          // every correction slow and visibly wrong for a moment.
          AVVideoMaxKeyFrameIntervalDurationKey: 1,
        ] as [String: Any],
      ]
    }
    // HEVC halves the bytes for the same picture; H.264 where the encoder
    // isn't there (older simulators, some Macs).
    var codec = AVVideoCodecType.hevc
    if !writer.canApply(outputSettings: videoSettings(codec), forMediaType: .video) {
      codec = .h264
    }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(codec))
    videoInput.transform = video.preferredTransform
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else { throw ShrinkError("The video encoder refused the settings.") }
    writer.add(videoInput)

    var audioInput: AVAssetWriterInput?
    if let audio = audio {
      // swiftlint:disable:next force_cast
      let hint = audio.formatDescriptions.first.map { $0 as! CMFormatDescription }
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
      input.expectsMediaDataInRealTime = false
      // e.g. uncompressed PCM in a .mov, which an mp4 cannot hold. Copying is
      // the only acceptable way to carry the audio (see the type comment),
      // so such a file is left as it is.
      guard writer.canAdd(input) else { return ["skipped": "audio can't be copied into mp4"] }
      writer.add(input)
      audioInput = input
    }

    let reader = try AVAssetReader(asset: asset)
    // The decoder scales to the output size, so the encoder is handed frames
    // that already fit.
    let videoOutput = AVAssetReaderTrackOutput(
      track: video,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: outWidth,
        kCVPixelBufferHeightKey as String: outHeight,
      ])
    videoOutput.alwaysCopiesSampleData = false
    reader.add(videoOutput)
    var audioOutput: AVAssetReaderTrackOutput?
    if let audio = audio {
      let output = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
      output.alwaysCopiesSampleData = false
      reader.add(output)
      audioOutput = output
    }

    guard reader.startReading() else {
      throw ShrinkError(reader.error?.localizedDescription ?? "AVAssetReader refused to start.")
    }
    guard writer.startWriting() else {
      reader.cancelReading()
      throw ShrinkError(writer.error?.localizedDescription ?? "AVAssetWriter refused to start.")
    }
    writer.startSession(atSourceTime: .zero)

    let group = DispatchGroup()
    func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, _ label: String) {
      group.enter()
      var finished = false
      input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
        while !finished && input.isReadyForMoreMediaData {
          if let buffer = output.copyNextSampleBuffer(), input.append(buffer) {
            continue
          }
          finished = true
          input.markAsFinished()
          group.leave()
        }
      }
    }
    pump(videoInput, videoOutput, "shrink.video")
    if let audioInput = audioInput, let audioOutput = audioOutput {
      pump(audioInput, audioOutput, "shrink.audio")
    }
    group.wait()

    if reader.status == .failed || writer.status == .failed {
      reader.cancelReading()
      writer.cancelWriting()
      throw ShrinkError(
        (writer.error ?? reader.error)?.localizedDescription ?? "Re-encoding failed part-way through.")
    }
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else {
      throw ShrinkError(writer.error?.localizedDescription ?? "The new file could not be finished.")
    }

    // A copy that is shorter than its source has lost the end of the
    // performance; refuse it rather than replace the original with it.
    let check = AVURLAsset(
      url: URL(fileURLWithPath: destination),
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let lost = abs(check.duration.seconds - asset.duration.seconds)
    if lost > 0.1 {
      throw ShrinkError(String(format: "The new file is %.2fs off the original's length.", lost))
    }
    if audio != nil && check.tracks(withMediaType: .audio).isEmpty {
      throw ShrinkError("The new file lost its audio track.")
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: destination)
    let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    return [
      "width": outWidth, "height": outHeight,
      "codec": codec == .hevc ? "hevc" : "h264", "bytes": bytes,
    ]
  }
}

// MARK: - encodeAac

/// The rendered score (lib/services/rendered_score_cache_io.dart): a WAV the
/// Dart side rendered, re-encoded as the app's own recordings are — AAC, mono,
/// 44.1 kHz, 64 kbps, in an MPEG-4 container — so it plays down the same path.
/// AVAudioFile (ExtAudioFile underneath, as `afconvert` uses) records the
/// encoder's 2112 priming frames in the file, so AVPlayer and the decoder skip
/// them and every rendered sample keeps its time.
extension MediaToolsPlugin {
  fileprivate func handleEncodeAac(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let input = arguments["input"] as? String,
      let output = arguments["output"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "input and output are required", details: nil))
      return
    }
    let bitRate = arguments["bitRate"] as? Int ?? 64000
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try MediaToolsPlugin.encodeAac(input: input, output: output, bitRate: bitRate)
        DispatchQueue.main.async { result(nil) }
      } catch {
        try? FileManager.default.removeItem(atPath: output)
        DispatchQueue.main.async {
          result(FlutterError(
            code: "encode_failed", message: error.localizedDescription, details: input))
        }
      }
    }
  }

  /// Written by AVAssetWriter as an .mp4, as the app's recordings are, not
  /// by AVAudioFile: AVAudioFile's .m4a carries the encoder's priming as
  /// iTunes gapless metadata (`udta`/iTunSMPB) with no edit list, where
  /// AVAssetWriter's .mp4 has a standard edit list (`edts`/`elst`). It was
  /// first suspected of the AirPlay loop stall, which turned out to be the
  /// seek of an ended item (VideoTransportPlugin.swift, `seekFresh`) and hit
  /// recordings too; kept so a generated file is structured like a recorded
  /// one.
  fileprivate static func encodeAac(input: String, output: String, bitRate: Int) throws {
    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)
    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    guard let track = asset.tracks(withMediaType: .audio).first,
      let desc = track.formatDescriptions.first,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
        desc as! CMAudioFormatDescription)?.pointee
    else {
      throw NSError(domain: "encodeAac", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "no audio track in \(input)"])
    }
    let reader = try AVAssetReader(asset: asset)
    let pcm = AVAssetReaderTrackOutput(
      track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    reader.add(pcm)
    // .mp4, not .m4a: with .m4a, AVAssetWriter too writes the iTunes metadata
    // and no edit list.
    let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
    let aac = AVAssetWriterInput(mediaType: .audio, outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: asbd.mSampleRate,
      AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
      AVEncoderBitRateKey: bitRate,
    ])
    aac.expectsMediaDataInRealTime = false
    writer.add(aac)
    guard reader.startReading(), writer.startWriting() else {
      throw reader.error ?? writer.error ?? NSError(domain: "encodeAac", code: 2)
    }
    writer.startSession(atSourceTime: .zero)

    let fed = DispatchSemaphore(value: 0)
    var finished = false
    aac.requestMediaDataWhenReady(on: DispatchQueue(label: "encodeAac")) {
      while !finished && aac.isReadyForMoreMediaData {
        if let buffer = pcm.copyNextSampleBuffer(), aac.append(buffer) { continue }
        finished = true
        aac.markAsFinished()
        fed.signal()
      }
    }
    fed.wait()
    let written = DispatchSemaphore(value: 0)
    writer.finishWriting { written.signal() }
    written.wait()
    if reader.status == .failed { throw reader.error ?? NSError(domain: "encodeAac", code: 3) }
    if writer.status != .completed {
      throw writer.error ?? NSError(domain: "encodeAac", code: 4)
    }
  }
}

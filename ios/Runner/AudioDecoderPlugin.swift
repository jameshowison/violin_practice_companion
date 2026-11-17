import AVFoundation
import Flutter

/// Decodes any container AVFoundation can open — mp3, m4a/aac, caf, aif, flac,
/// and the audio track of an mp4/mov — to mono `Float32` PCM at the source
/// sample rate, for the score-to-audio DTW alignment on the Dart side.
///
/// The Dart side never sends WAV here: `package:wav` reads that in pure Dart,
/// which is faster than a channel round trip and works under `flutter test`.
/// See `lib/services/audio_decoder_io.dart`.
///
/// Registered by hand from `AppDelegate` rather than being a pub package: it
/// is about thirty lines of AVFoundation and exists only to serve this app's
/// one alignment pipeline.
public class AudioDecoderPlugin: NSObject, FlutterPlugin {
  private static let channelName = "violin_practice_companion/audio_decoder"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(AudioDecoderPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "shrinkVideo" {
      handleShrinkVideo(call, result: result)
      return
    }
    guard call.method == "decodeToPcm" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let path = arguments["path"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "path is required", details: nil))
      return
    }

    // Decoding a whole file is seconds of CPU for a long recording; the main
    // thread is also the UI thread and the caller is already showing a
    // progress indicator.
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let decoded = try self.decode(path: path)
        DispatchQueue.main.async {
          result([
            "sampleRate": decoded.sampleRate,
            "samples": FlutterStandardTypedData(float32: decoded.samples),
          ])
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "decode_failed", message: error.localizedDescription, details: path))
        }
      }
    }
  }

  private struct Decoded {
    let samples: Data
    let sampleRate: Double
  }

  private enum DecodeError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    var errorDescription: String? {
      switch self {
      case .noAudioTrack:
        // An imported video with no audio track is a real case, and the Dart
        // side turns this into "plays, but cannot drive the highlight".
        return "The file has no audio track."
      case .readerFailed(let detail):
        return detail
      }
    }
  }

  /// Reads the file's first audio track, asking AVFoundation to convert it on
  /// the way out to 32-bit float, mono, non-interleaved, at the track's own
  /// sample rate. Letting the reader do the mixdown avoids hand-written
  /// channel maths and gets whatever resampling quality the platform has.
  private func decode(path: String) throws -> Decoded {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw DecodeError.noAudioTrack
    }

    // The track's natural rate, falling back to 44.1 kHz when the format
    // description doesn't state one.
    var sampleRate = 44100.0
    if let description = track.formatDescriptions.first {
      // swiftlint:disable:next force_cast
      let format = description as! CMAudioFormatDescription
      if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
        sampleRate = basic.pointee.mSampleRate
      }
    }

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: sampleRate,
      ])
    output.alwaysCopiesSampleData = false
    reader.add(output)

    guard reader.startReading() else {
      throw DecodeError.readerFailed(
        reader.error?.localizedDescription ?? "AVAssetReader refused to start.")
    }

    var samples = Data()
    while let buffer = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      var length = 0
      var pointer: UnsafeMutablePointer<Int8>?
      let status = CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
        dataPointerOut: &pointer)
      if status == kCMBlockBufferNoErr, let pointer = pointer, length > 0 {
        samples.append(UnsafeBufferPointer(start: pointer, count: length))
      }
      CMSampleBufferInvalidate(buffer)
    }

    if reader.status == .failed {
      throw DecodeError.readerFailed(
        reader.error?.localizedDescription ?? "Decoding failed part-way through.")
    }

    return Decoded(samples: samples, sampleRate: sampleRate)
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
extension AudioDecoderPlugin {
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
        let outcome = try AudioDecoderPlugin.shrinkVideo(
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

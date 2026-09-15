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

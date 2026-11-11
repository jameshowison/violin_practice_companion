import Flutter
import UIKit
import Vision

/// Printed-text recognition with Apple Vision, for reading a scanned piece's
/// title. Dart decides WHERE to look (the strip around the top of the user's
/// music crop, `lib/services/title_region.dart`) and WHICH line is the title;
/// this only runs `VNRecognizeTextRequest` over that region and reports every
/// line it read.
///
/// Coordinates crossing the channel are normalised to the upright image, with
/// a TOP-left origin (as Flutter thinks of images); Vision's own are
/// bottom-left, so both directions are flipped here.
///
/// Registered by hand from `AppDelegate`, like `AudioDecoderPlugin`.
public class TextRecognitionPlugin: NSObject, FlutterPlugin {
  private static let channelName = "violin_practice_companion/text_recognition"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TextRecognitionPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "recognizeText" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let data = (args["image"] as? FlutterStandardTypedData)?.data
    else {
      result(FlutterError(code: "bad_args", message: "image bytes required", details: nil))
      return
    }
    let region = (args["region"] as? [Double]) ?? [0, 0, 1, 1]
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let lines = try Self.recognize(data: data, region: region)
        DispatchQueue.main.async { result(lines) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "recognize_failed", message: "\(error)", details: nil))
        }
      }
    }
  }

  private static func recognize(data: Data, region: [Double]) throws -> [[String: Any]] {
    guard let image = UIImage(data: data), let cgImage = image.cgImage else {
      throw NSError(
        domain: "TextRecognition", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "could not decode image"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    // Latin-script languages only: the books print titles in English with
    // French/German/Spanish translations, and leaving the choice to Vision
    // read pencil marks as Cyrillic.
    request.automaticallyDetectsLanguage = false
    request.recognitionLanguages = ["en-US", "fr-FR", "de-DE", "es-ES", "it-IT"]
    if region.count == 4 {
      let (x, y, w, h) = (region[0], region[1], region[2], region[3])
      // Vision clamps nothing: a region outside [0,1] fails the request.
      request.regionOfInterest = CGRect(x: x, y: 1 - y - h, width: w, height: h)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    // The orientation makes Vision work on the upright image — the one the
    // cropper showed the user and Flutter's decoder produced — so
    // regionOfInterest and the boxes are in that frame too.
    let handler = VNImageRequestHandler(
      cgImage: cgImage, orientation: cgOrientation(image.imageOrientation), options: [:])
    try handler.perform([request])

    let roi = request.regionOfInterest
    return (request.results ?? []).compactMap { observation in
      guard let top = observation.topCandidates(1).first else { return nil }
      // Boxes come back relative to regionOfInterest; map to the whole image.
      let b = observation.boundingBox
      let x = roi.minX + b.minX * roi.width
      let w = b.width * roi.width
      let h = b.height * roi.height
      let yBottom = roi.minY + b.minY * roi.height
      return [
        "text": top.string,
        "confidence": Double(top.confidence),
        "box": [Double(x), Double(1 - yBottom - h), Double(w), Double(h)],
      ]
    }
  }

  private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch o {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    case .upMirrored: return .upMirrored
    case .downMirrored: return .downMirrored
    case .leftMirrored: return .leftMirrored
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
  }
}

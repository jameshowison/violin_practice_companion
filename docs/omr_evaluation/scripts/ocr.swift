// Lyrics spike, step 1: what Apple Vision reads off a score page.
//
//   swift docs/omr_evaluation/scripts/ocr.swift page.png > ocr.json
//
// Prints every text observation with its box in image pixels (origin top-left,
// unlike Vision's bottom-left unit square), plus one box per character (in
// practice Vision returns the word box for each). Language correction is off:
// it "fixes" syllables into words.
//
// The page is read twice: in overlapping horizontal strips, and whole. Each
// pass skips lines the other reads (a whole page lost a lyric line of a 1917
// songbook that its strip read perfectly, and vice versa). Strips are H tall
// every H/2, each keeping only what is centred in its middle half, so a line
// is read once per pass; whole-page reads are then added only where no strip
// read overlaps them.
// See docs/lyrics_from_scans.md.
import AppKit
import Foundation
import Vision

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard let image = NSImage(contentsOfFile: path),
      let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  FileHandle.standardError.write("usage: ocr.swift <image>\n".data(using: .utf8)!)
  exit(1)
}
// Optional upscaling (OCR_MIN_WIDTH=2400): it does recover one-letter words
// ("I", "a") Vision drops on small text, but measured over six keyed pages it
// cost more than it found (80% vs 90% exact), so it is off by default. Boxes
// are always in the ORIGINAL image's pixels.
let target = Double(ProcessInfo.processInfo.environment["OCR_MIN_WIDTH"] ?? "0") ?? 0
let scale = max(1.0, target / Double(original.width))
let cg: CGImage = {
  guard scale > 1 else { return original }
  let w = Int(Double(original.width) * scale), h = Int(Double(original.height) * scale)
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.interpolationQuality = .high
  ctx.draw(original, in: CGRect(x: 0, y: 0, width: w, height: h))
  return ctx.makeImage()!
}()
let W = Double(cg.width), H = Double(cg.height)
let stripH = max(200.0, (H / 8).rounded())
let step = stripH / 2

func r1(_ v: Double) -> Double { (v / scale * 10).rounded() / 10 }  // to original px

func recognise(_ img: CGImage) throws -> [VNRecognizedTextObservation] {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.usesLanguageCorrection = false
  request.minimumTextHeight = 0
  try VNImageRequestHandler(cgImage: img).perform([request])
  return request.results ?? []
}

func record(_ obs: VNRecognizedTextObservation, _ px: (CGRect) -> [Double]) -> [String: Any]? {
  guard let top = obs.topCandidates(1).first else { return nil }
  let s = top.string
  var chars: [[String: Any]] = []
  var i = s.startIndex
  while i < s.endIndex {
    let j = s.index(after: i)
    if let b = try? top.boundingBox(for: i..<j) {
      chars.append(["c": String(s[i..<j]), "box": px(b.boundingBox)])
    }
    i = j
  }
  return ["text": s, "conf": top.confidence, "box": px(obs.boundingBox), "chars": chars]
}

var out: [[String: Any]] = []
var y0 = 0.0
while true {
  let h = min(stripH, H - y0)
  guard let strip = cg.cropping(to: CGRect(x: 0, y: y0, width: W, height: h)) else { break }
  let results = try recognise(strip)

  // Which part of this strip it owns: its middle half, widened at the ends.
  let first = y0 == 0, last = y0 + stripH >= H
  let lo = first ? 0 : y0 + stripH / 4
  let hi = last ? H : y0 + 3 * stripH / 4

  func px(_ r: CGRect) -> [Double] {  // strip unit square -> page pixels
    [r1(r.minX * W), r1(y0 + (1 - r.maxY) * h), r1(r.width * W), r1(r.height * h)]
  }
  for obs in results {
    guard let rec = record(obs, px), let box = rec["box"] as? [Double] else { continue }
    let cy = (box[1] + box[3] / 2) * scale  // box is in original px; strips in scaled
    if cy >= lo && cy < hi { out.append(rec) }
  }
  if last { break }
  y0 += step
}

// The whole page, for what the strips missed.
func overlaps(_ a: [Double], _ b: [Double]) -> Bool {
  let w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
  let h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
  return w > 0 && h > 0.3 * min(a[3], b[3])
}
let fromStrips = out.compactMap { $0["box"] as? [Double] }
for obs in try recognise(cg) {
  let px: (CGRect) -> [Double] = { r in
    [r1(r.minX * W), r1((1 - r.maxY) * H), r1(r.width * W), r1(r.height * H)]
  }
  guard let rec = record(obs, px), let box = rec["box"] as? [Double] else { continue }
  if !fromStrips.contains(where: { overlaps($0, box) }) { out.append(rec) }
}
let json = try JSONSerialization.data(
  withJSONObject: ["width": W / scale, "height": H / scale, "observations": out], options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)

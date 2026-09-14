import CoreGraphics
import Vision

/// Reads UI chrome before full-frame downscaling loses small menu and address-bar text.
enum ScreenshotHeaderOCR {
  static func crop(from image: CGImage) -> CGImage? {
    let height = max(1, Int(Double(image.height) * 0.12))
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: height)
    guard let crop = image.cropping(to: bounds),
      let context = CGContext(data: nil, width: image.width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // CGImage cropping retains the full source buffer. Copy pixels before caching the header.
    context.draw(crop, in: bounds)
    return context.makeImage()
  }

  static func text(in image: CGImage) -> String {
    guard let header = crop(from: image) else { return "" }
    return text(inHeader: header)
  }

  static func text(inHeader header: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    request.usesLanguageCorrection = false
    do {
      try VNImageRequestHandler(cgImage: header).perform([request])
      let lines = (request.results ?? []).sorted {
        let leftRow = Int(($0.boundingBox.midY * 20).rounded())
        let rightRow = Int(($1.boundingBox.midY * 20).rounded())
        return leftRow == rightRow ? $0.boundingBox.minX < $1.boundingBox.minX : leftRow > rightRow
      }.compactMap { $0.topCandidates(1).first?.string }
      return String(lines.joined(separator: " | ").prefix(1200))
    } catch {
      // OCR is supplementary evidence; an unavailable recognizer must not drop a frame.
      return ""
    }
  }
}

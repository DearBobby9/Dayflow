import CoreGraphics
import XCTest

@testable import Dayflow

final class FoundationModelsHeaderOCRTests: XCTestCase {
  private final class ReleaseCounter {
    var count = 0
  }

  private func makeImage(counter: ReleaseCounter) throws -> CGImage {
    let width = 100
    let height = 100
    let byteCount = width * height * 4
    let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    let bytes = pixels.initializeMemory(as: UInt8.self, repeating: 255, count: byteCount)
    for row in 0..<height {
      for column in 0..<width {
        let offset = (row * width + column) * 4
        bytes[offset] = row < 12 ? 255 : 0
        bytes[offset + 1] = 0
        bytes[offset + 2] = row < 12 ? 0 : 255
      }
    }
    let provider = try XCTUnwrap(CGDataProvider(
      dataInfo: Unmanaged.passRetained(counter).toOpaque(), data: pixels, size: byteCount
    ) { info, data, _ in
      Unmanaged<ReleaseCounter>.fromOpaque(info!).takeRetainedValue().count += 1
      UnsafeMutableRawPointer(mutating: data).deallocate()
    })
    return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  }

  func testHeaderCopiesTopRowsWithoutRetainingTheFullFrame() throws {
    let counter = ReleaseCounter()
    let header = try autoreleasepool {
      let image = try makeImage(counter: counter)
      return try XCTUnwrap(ScreenshotHeaderOCR.crop(from: image))
    }

    XCTAssertEqual(counter.count, 1, "Caching the header must release the full screenshot buffer")
    XCTAssertEqual(header.width, 100)
    XCTAssertEqual(header.height, 12)
    let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 12,
      bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(header, in: CGRect(x: 0, y: 0, width: 100, height: 12))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    for offset in stride(from: 0, to: 100 * 12 * 4, by: 4) {
      XCTAssertEqual(bytes[offset], 255)
      XCTAssertEqual(bytes[offset + 1], 0)
      XCTAssertEqual(bytes[offset + 2], 0)
    }
  }
}

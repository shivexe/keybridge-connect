import AppKit
import Vision
import XCTest
@testable import KeybridgeConnect

final class PairingCodeTests: XCTestCase {
  func testPairingCodeDecodesAtDisplaySize() throws {
    let invitation: Object = ["version": 1, "vaultId": UUID().uuidString.lowercased(),
      "pairId": UUID().uuidString.lowercased(), "desktopName": "A Mac with a longer display name",
      "url": "https://192.168.1.123:49443", "expiresAt": 1790429000,
      "publicKey": String(repeating: "a", count: 43), "secret": String(repeating: "b", count: 43), "certificateSha256": String(repeating: "c", count: 43)]
    let image = try XCTUnwrap(PairingCode.image(invitation))
    XCTAssertLessThanOrEqual(image.size.width, 360)
    let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    for factor in [1.0, 0.5] {
      let width = Int(Double(cg.width) * factor)
      let context = try XCTUnwrap(CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.interpolationQuality = .none
      context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: width))
      let scaled = try XCTUnwrap(context.makeImage())
      let request = VNDetectBarcodesRequest()
      request.symbologies = [.qr]
      try VNImageRequestHandler(cgImage: scaled).perform([request])
      XCTAssertEqual(request.results?.first?.payloadStringValue, String(data: try Wire.data(invitation), encoding: .utf8))
    }
  }
}

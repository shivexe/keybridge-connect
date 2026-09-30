import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingCode: View {
  let invitation: Object
  static func image(_ invitation: Object, maximumSize: CGFloat = 360) -> NSImage? {
    guard let data = try? Wire.data(invitation) else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = data
    filter.correctionLevel = "M"
    guard let code = filter.outputImage else { return nil }
    let width = code.extent.width + 8
    let pointsPerModule = max(1, floor(maximumSize / width))
    let background = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: width))
    let padded = code.transformed(by: CGAffineTransform(translationX: 4, y: 4)).composited(over: background)
    let scaled = padded.transformed(by: CGAffineTransform(scaleX: pointsPerModule * 2, y: pointsPerModule * 2))
    guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: width * pointsPerModule, height: width * pointsPerModule))
  }
  var body: some View {
    if let image = Self.image(invitation) {
      Image(nsImage: image).interpolation(.none)
        .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Pairing QR code")
    }
  }
}

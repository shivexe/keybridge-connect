import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 108, y: CGFloat(pixels) / 108)
    NSColor(red: 0.125, green: 0.42, blue: 0.82, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 98, height: 98), xRadius: 22, yRadius: 22).fill()
    let path = NSBezierPath(ovalIn: NSRect(x: 26, y: 54, width: 28, height: 28))
    path.move(to: NSPoint(x: 50, y: 58)); path.line(to: NSPoint(x: 77, y: 31))
    path.move(to: NSPoint(x: 65, y: 43)); path.line(to: NSPoint(x: 72, y: 50))
    path.move(to: NSPoint(x: 73, y: 35)); path.line(to: NSPoint(x: 80, y: 42))
    path.lineWidth = 7; path.lineCapStyle = .round; path.lineJoinStyle = .round
    NSColor.white.setStroke(); path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}

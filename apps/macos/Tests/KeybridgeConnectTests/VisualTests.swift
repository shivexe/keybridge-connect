import AppKit
import SwiftUI
import XCTest
@testable import KeybridgeConnect

final class VisualTests: XCTestCase {
  @MainActor func testCompanionScreens() throws {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let output = project.appendingPathComponent(".work/ui-review")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func render<V: View>(_ view: V, _ name: String, _ scheme: ColorScheme) throws {
      _ = NSApplication.shared
      let host = NSHostingView(rootView: view.frame(width: 650, height: 620)
        .background(scheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color(red: 0.98, green: 0.98, blue: 0.99))
        .environment(\.colorScheme, scheme).tint(Color(red: 0.12, green: 0.42, blue: 0.82)))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 620),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      window.orderFrontRegardless()
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
      let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(png.count, 10000, "Screen rendered without visible content")
      window.orderOut(nil)
      try png.write(to: output.appendingPathComponent(name + ".png"))
    }
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .light ? "light" : "dark"
      try render(SyncOverview(title: "You’re up to date", detail: "Your phone has received your latest passwords.",
        phone: "iQOO Z6 Pro", count: 24, busy: false, attention: false, delivered: true,
        receipt: Date(timeIntervalSince1970: 1790000000), actionTitle: "Sync now",
        action: {}, cancel: {}, passwords: {}, pair: {}), "mac-overview-" + suffix, scheme)
      try render(LockedCompanionView(detail: "", cleanup: false, unlock: {}, recover: {}), "mac-locked-" + suffix, scheme)
      try render(SyncOverview(title: "Syncing your passwords", detail: "Approve Apple’s authentication. Sync will continue automatically.",
        phone: "iQOO Z6 Pro", count: 24, busy: true, attention: false, delivered: false,
        receipt: nil, actionTitle: "Syncing…", action: {}, cancel: {}, passwords: {}, pair: {}), "mac-syncing-" + suffix, scheme)
    }
  }
}

import AppKit
import ApplicationServices
import OSLog

enum AutomationFailure: String, Error {
  case accessibilityRequired, passwordsUnavailable, changedUI, timedOut, cancelled
}

/// English-language, dummy-only adapter. Every action is confined to Passwords' AX tree.
/// This is deliberately separate from storage so unexpected UI cannot redirect an export.
@MainActor
final class PasswordExportAutomation {
  private let logger = Logger(subsystem: "dev.keybridge.connect.mac", category: "export")
  private(set) var stage = "opening_passwords"
  private func progress(_ stage: String, _ message: String) {
    self.stage = stage
    logger.info("Export stage: \(stage, privacy: .public)")
    report(message)
  }
  private var application: AXUIElement!
  private var process: NSRunningApplication!
  private var exportStarted = false
  var cancelled = false
  private var ownedSave: AXUIElement?
  private(set) var dialogCompleted = false
  enum Intent: String, CaseIterable { case dummy, selected, full }
  var report: (String) -> Void = { _ in }

  static var trusted: Bool { AXIsProcessTrusted() }

  private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
    guard status == .success else { return nil }
    return result
  }
  private func text(_ element: AXUIElement, _ attribute: String) -> String {
    let content = value(element, attribute)
    if let string = content as? String { return string }
    if let attributed = content as? NSAttributedString { return attributed.string }
    return ""
  }
  private func children(_ element: AXUIElement) -> [AXUIElement] {
    value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
  }
  private func nodes(_ root: AXUIElement) -> [AXUIElement] {
    // Breadth-first traversal reaches toolbar controls before a large vault's row descendants.
    var queue = [root]
    var result: [AXUIElement] = []
    var index = 0
    while index < queue.count, result.count < 1200 {
      let current = queue[index]
      index += 1
      result.append(current)
      queue.append(contentsOf: children(current))
    }
    return result
  }
  private func named(_ name: String, role: String? = nil, root: AXUIElement? = nil) -> AXUIElement?
  {
    nodes(root ?? application).first { element in
      (role == nil || text(element, kAXRoleAttribute) == role)
        && (value(element, kAXEnabledAttribute) as? Bool) != false
        && [kAXTitleAttribute, kAXDescriptionAttribute].contains { text(element, $0) == name }
    }
  }
  private func isDummyRow(_ element: AXUIElement) -> Bool {
    guard text(element, kAXRoleAttribute) == kAXRowRole else { return false }
    let direct = text(element, kAXValueAttribute)
    if direct.split(separator: "\n").first == "keybridge.invalid" { return true }
    return nodes(element).contains {
      self.text($0, kAXRoleAttribute) == kAXStaticTextRole
        && [self.text($0, kAXValueAttribute), self.text($0, kAXTitleAttribute)].contains(
          "keybridge.invalid")
    }
  }
  private func press(_ element: AXUIElement) throws {
    guard !cancelled else { throw AutomationFailure.cancelled }
    guard (value(element, kAXEnabledAttribute) as? Bool) != false,
      AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    else { throw AutomationFailure.changedUI }
  }
  private func set(_ element: AXUIElement, _ string: String) throws {
    guard
      AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, string as CFString)
        == .success
    else { throw AutomationFailure.changedUI }
  }
  private func wait(seconds: TimeInterval = 60, for resolve: () -> AXUIElement?) async throws
    -> AXUIElement
  {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      guard !cancelled else { throw AutomationFailure.cancelled }
      try Task.checkCancellation()
      if let found = resolve() { return found }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw AutomationFailure.timedOut
  }
  private func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
    guard !cancelled,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier,
      let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    else { throw AutomationFailure.changedUI }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }

  func dismissExportIfPresent() {
    guard exportStarted, let ownedSave,
      nodes(ownedSave).contains(where: { text($0, kAXIdentifierAttribute) == "saveAsNameTextField" }
      ),
      let button = named("Cancel", role: kAXButtonRole, root: ownedSave)
    else { return }
    _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
  }

  func confirmWriterStopped() async throws {
    guard application != nil else { return }
    _ = try await wait(seconds: 10) {
      self.nodes(self.application).contains(where: {
        self.text($0, kAXIdentifierAttribute) == "saveAsNameTextField"
      }) ? nil : self.application
    }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    guard
      !nodes(application).contains(where: {
        text($0, kAXIdentifierAttribute) == "saveAsNameTextField"
      })
    else { throw AutomationFailure.changedUI }
  }

  func export(to destination: URL, intent: Intent) async throws {
    cancelled = false
    dialogCompleted = false
    exportStarted = false
    ownedSave = nil
    guard Self.trusted else { throw AutomationFailure.accessibilityRequired }
    let configuration = NSWorkspace.OpenConfiguration()
    process = try await NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: "/System/Applications/Passwords.app"),
      configuration: configuration)
    application = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 2)
    progress("unlocking_passwords", "Unlock Apple Passwords. Sync will continue automatically.")
    let search = try await wait(seconds: 120) {
      self.nodes(self.application).first {
        self.text($0, kAXRoleAttribute) == kAXTextFieldRole
          && (self.value($0, kAXEnabledAttribute) as? Bool) != false
          && (self.text($0, kAXSubroleAttribute) == kAXSearchFieldSubrole
            || self.text($0, kAXDescriptionAttribute) == "Search"
            || self.text($0, kAXPlaceholderValueAttribute) == "Search"
            || self.text($0, kAXRoleDescriptionAttribute) == "search text field")
      }
    }
    if intent == .dummy {
      progress("selecting_passwords", "Finding your test login…")
      try set(search, "keybridge.invalid")
      let row = try await wait(seconds: 10) {
        let matches = self.nodes(self.application).filter { self.isDummyRow($0) }
        return matches.count == 1 ? matches[0] : nil
      }
      report("Selecting the dummy login…")
      guard
        AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
          == .success
      else { throw AutomationFailure.changedUI }
      _ = try await wait(seconds: 5) {
        let selected = self.nodes(self.application).filter {
          self.text($0, kAXRoleAttribute) == kAXRowRole
            && self.value($0, kAXSelectedAttribute) as? Bool == true && self.isDummyRow($0)
        }
        return selected.count == 1 && CFEqual(selected[0], row) ? row : nil
      }
    } else {
      try set(search, "")
      if intent == .selected {
        guard
          nodes(application).contains(where: {
            text($0, kAXRoleAttribute) == kAXRowRole
              && value($0, kAXSelectedAttribute) as? Bool == true
          })
        else { throw AutomationFailure.changedUI }
      }
    }
    guard let menuBar = value(application, kAXMenuBarAttribute),
      CFGetTypeID(menuBar) == AXUIElementGetTypeID()
    else { throw AutomationFailure.changedUI }
    let bar = unsafeBitCast(menuBar, to: AXUIElement.self)
    progress("opening_export", "Preparing Apple Passwords export…")
    let file = try await wait(seconds: 120) { self.named("File", root: bar) }
    try press(file)
    let export = try await wait(seconds: 120) {
      self.named(
        intent == .full ? "Export All Passwords to File…" : "Export Selected Password to File…",
        root: bar)
    }
    exportStarted = true
    try press(export)
    progress("confirming_export", "Confirming Apple’s export dialog…")
    let confirmation = try await wait(seconds: 120) {
      self.named(intent == .full ? "Export Passwords…" : "Export Password…", role: kAXButtonRole)
    }
    try press(confirmation)
    progress("authorizing_export", "Approve Apple’s authentication. Sync will continue automatically.")
    let saveName = try await wait(seconds: 120) {
      self.nodes(self.application).first {
        self.text($0, kAXRoleAttribute) == kAXTextFieldRole
          && self.text($0, kAXIdentifierAttribute) == "saveAsNameTextField"
      }
    }
    var ancestor = saveName
    for _ in 0..<8 {
      guard let parent = value(ancestor, kAXParentAttribute),
        CFGetTypeID(parent) == AXUIElementGetTypeID()
      else { break }
      ancestor = unsafeBitCast(parent, to: AXUIElement.self)
      if [kAXSheetRole, kAXWindowRole].contains(text(ancestor, kAXRoleAttribute)) {
        ownedSave = ancestor
        break
      }
    }
    progress("saving_export", "Saving passwords securely…")
    guard ownedSave != nil else { throw AutomationFailure.changedUI }
    try set(saveName, destination.lastPathComponent)
    process.activate()
    // Standard Go to Folder sheet, with focus guarded before keyboard input.
    try key(5, flags: [.maskCommand, .maskShift])
    let path = try await wait(seconds: 5) {
      self.nodes(self.application).first {
        self.text($0, kAXIdentifierAttribute) == "PathTextField"
      }
    }
    try set(path, destination.deletingLastPathComponent().path)
    guard text(path, kAXValueAttribute) == destination.deletingLastPathComponent().path
    else { throw AutomationFailure.changedUI }
    try key(36)
    let save = try await wait(seconds: 10) {
      // Wait until the Go to Folder sheet has closed before pressing the final Save.
      guard
        !self.nodes(self.application).contains(where: {
          self.text($0, kAXIdentifierAttribute) == "PathTextField"
        })
      else { return nil }
      return self.named("Save", role: kAXButtonRole)
    }
    try press(save)
    try await confirmWriterStopped()
    dialogCompleted = true
    progress("validating_export", "Preparing your passwords for your phone…")
  }
}

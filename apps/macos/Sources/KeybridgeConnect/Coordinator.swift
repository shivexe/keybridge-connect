import AppKit
import ApplicationServices
import OSLog
import SwiftUI

actor WorkspaceManager {
  private var workspace: ExportWorkspace?
  func prepare(_ root: URL) throws -> URL {
    try Wire.require(workspace == nil)
    workspace = try ExportWorkspace.create(in: root)
    return workspace!.csv
  }
  func read() throws -> Data {
    guard let workspace else { throw BridgeFailure.unsafeWorkspace }
    return try workspace.readCSV()
  }
  func cleanup() throws {
    guard let workspace else { return }
    try workspace.cleanup()
    self.workspace = nil
  }
}
@MainActor final class Coordinator: ObservableObject {
  let vault = MacVault()
  lazy var sharing = Sharing(vault)
  private let workspaces = WorkspaceManager()
  private var automation: PasswordExportAutomation?
  private var operation: Task<Void, Never>?
  private var timer: Timer?
  private var lastActivity = Date()
  private let reminder = SyncReminder()
  @Published var phase = "locked"
  @Published var detail = "Unlock Keybridge Connect to begin."
  @Published var intent = PasswordExportAutomation.Intent.full
  @Published var schedule = 0
  @Published var pendingAction = false
  @Published var interface = ""
  @Published var networks: [PairingNetwork] = []
  @Published var pairingError: String?
  @Published var preparingPair = false
  @Published var diagnostics: [String: Int] = [:]
  @Published var records: [Object] = []
  @Published var busy = false
  private var observers: [NSObjectProtocol] = []
  init() {
    schedule = reminder.interval
    pendingAction = reminder.isDue()
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
    {
      observers.append(
        workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in await self?.lock() }
        })
    }
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
      ) { [weak self] _ in Task { @MainActor in await self?.lock() } })
    do { try vault.initialize() } catch {
      phase = "cleanup_blocked"
      detail = "Startup cleanup requires attention. No new export can start."
    }
  }
  func touch() { lastActivity = Date() }
  func unlock() {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await vault.unlock()
        phase = "ready"
        detail = "Ready. Apple Passwords remains your Mac password manager."
        records = vault.state?["records"] as? [Object] ?? []
        diagnostics["keybridgeUnlock", default: 0] += 1
        touch()
        if vault.state?["active"] != nil {
          do { try await connect() } catch {
            detail = "Connect this Mac to your phone’s Wi-Fi, then try again."
          }
        }
      } catch VaultFailure.keychain(let status) {
        phase = "locked"
        detail =
          "Keychain could not create the vault key (\(status)). Existing encrypted state was preserved."
      } catch {
        phase = "locked"
        detail = "Could not unlock. Existing encrypted state was preserved."
      }
    }
  }
  func discoverNetworks() {
    networks = PairingNetwork.discover()
    if !networks.contains(where: { $0.address == interface }) {
      interface = networks.first?.address ?? ""
    }
  }
  func connect() async throws {
    discoverNetworks()
    try Wire.require(!interface.isEmpty)
    let expected = "https://\(interface.contains(":") ? "[\(interface)]" : interface):49444"
    if sharing.url != expected {
      await sharing.stop()
      try await sharing.start(interface)
    }
  }
  func pair() async {
    guard !preparingPair, !busy else { return }
    preparingPair = true
    pairingError = nil
    defer { preparingPair = false }
    do {
      try await connect()
      if (vault.state?["generation"] as? Int ?? 0) == 0 { try sharing.publish([]) }
      try sharing.invite()
      touch()
    } catch {
      pairingError =
        networks.isEmpty
        ? "Connect this Mac to Wi-Fi, then try again. Your phone needs to be on the same network."
        : "Couldn’t start pairing. If you already approved a phone, finish or cancel that connection before trying again."
    }
  }
  func syncNow() {
    guard !busy, vault.state != nil, phase != "cleanup_blocked" else { return }
    busy = true
    reminder.acknowledge()
    pendingAction = false
    touch()
    operation = Task {
      if !AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
      {
        phase = "awaiting_authentication"
        detail =
          "Enable Keybridge Connect in System Settings → Privacy & Security → Accessibility. Sync will continue automatically."
        let deadline = Date().addingTimeInterval(300)
        while !AXIsProcessTrusted(), Date() < deadline, !Task.isCancelled {
          do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
        }
        guard AXIsProcessTrusted(), !Task.isCancelled else {
          phase = "cancelled"
          detail =
            "Sync didn’t start. Accessibility access is required to export from Apple Passwords."
          busy = false
          operation = nil
          return
        }
      }
      await performExport()
      busy = false
      operation = nil
      touch()
    }
  }
  private func performExport() async {
    var published = false
    let adapter = PasswordExportAutomation()
    automation = adapter
    adapter.report = { [weak self] text in
      self?.detail = text
      if text.contains("Approve") || text.contains("Unlock") {
        self?.phase = "awaiting_authentication"
        self?.diagnostics["appleAuthenticationOpportunity", default: 0] += 1
      }
    }
    do {
      try await connect()
      phase = "exporting"
      let destination = try await workspaces.prepare(vault.runtime)
      try await adapter.export(to: destination, intent: intent)
      try Task.checkCancellation()
      try Wire.require(adapter.dialogCompleted)
      phase = "importing"
      var data = try await workspaces.read()
      defer { data.resetBytes(in: 0..<data.count) }
      try await Task.sleep(nanoseconds: 750_000_000)
      let second = try await workspaces.read()
      try Wire.require(data == second)
      let incoming = try Importer.rows(data, dummy: intent == .dummy)
      try Wire.require(!incoming.isEmpty)
      let candidate = try Importer.reconcile(records, incoming, complete: intent == .full)
      try Task.checkCancellation()
      phase = "cleaning_up"
      try await workspaces.cleanup()
      try Task.checkCancellation()
      try sharing.publish(candidate)
      published = true
      records = candidate
      phase = "pending_delivery"
      detail = "Passwords are ready. Keep Keybridge open on your phone to receive them."
      let deadline = Date().addingTimeInterval(60)
      while Date() < deadline && !Task.isCancelled {
        if sharing.status == "synced" {
          phase = "synced"
          detail = "Your passwords are up to date on your phone."
          break
        }
        try await Task.sleep(nanoseconds: 500_000_000)
      }
      if phase != "synced" {
        phase = "pending_delivery"
        detail = "Open and unlock Keybridge on your phone to finish syncing."
      }
    } catch {
      let stage = adapter.stage
      let failure = (error as? AutomationFailure)?.rawValue ?? "operation_failed"
      Logger(subsystem: "dev.keybridge.connect.mac", category: "export")
        .error("Export stopped at \(stage, privacy: .public): \(failure, privacy: .public)")
      let wasCancelled = Task.isCancelled
      if published {
        phase = sharing.status == "synced" ? "synced" : "pending_delivery"
        detail =
          "Your passwords are saved. Open Keybridge on your phone to finish syncing."
        automation = nil
        return
      }
      adapter.dismissExportIfPresent()
      do {
        adapter.cancelled = false
        try await Task.detached { [adapter] in try await adapter.confirmWriterStopped() }.value
        phase = "cleaning_up"
        try await workspaces.cleanup()
        if sharing.status == "synced" {
          phase = "synced"
          detail = "Phone receipt was already recorded. Cancellation cannot undo delivery."
        } else {
          phase = wasCancelled ? "cancelled" : "integrity_failure"
          detail =
            wasCancelled
            ? "Sync cancelled. Your saved passwords haven’t changed."
            : (error as? AutomationFailure) == .timedOut
              ? "Apple’s export didn’t finish in time. Your saved passwords haven’t changed."
              : "Couldn’t finish Apple’s export. Your saved passwords haven’t changed. Try again with Apple Passwords unlocked."
        }
      } catch {
        phase = "cleanup_blocked"
        detail =
          "Cleanup is blocked. Keep Keybridge open, close only its export dialog, then recover. No new export is allowed."
      }
    }
    automation = nil
  }
  func cancel() {
    automation?.cancelled = true
    operation?.cancel()
  }
  func recover() async {
    guard !busy else { return }
    do {
      try await workspaces.cleanup()
      try vault.initialize()
      phase = vault.state == nil ? "locked" : "ready"
      detail = "Cleanup finished. You can sync again."
    } catch {
      phase = "cleanup_blocked"
      detail = "Cleanup remains blocked. Do not delete mounted folders manually."
    }
  }
  func lock() async {
    vault.cancelUnlock()
    cancel()
    if let operation { await operation.value }
    await sharing.stop()
    vault.lock()
    records = []
    if phase != "cleanup_blocked" {
      phase = "locked"
      detail = "Locked. Delivery resumes after unlock."
    }
  }
  func tick() {
    if phase == "pending_delivery" && sharing.status == "synced" {
      phase = "synced"
      detail = "Confirmed on Android."
    }
    if vault.state != nil && !busy && Date().timeIntervalSince(lastActivity) >= 300 {
      Task { await lock() }
    }
    if !busy && !pendingAction && reminder.isDue() {
      pendingAction = true
      detail = "Scheduled sync needs your action. Click Sync now when ready."
    }
  }
  func updateSchedule(_ value: Int) {
    schedule = value
    reminder.update(value)
    pendingAction = false
  }
  func remove(_ id: String) {
    guard !busy else { return }
    do {
      let next = records.filter { $0["id"] as? String != id }
      try sharing.publish(next)
      records = next
      phase = "pending_delivery"
    } catch { detail = "Removal failed. The previous snapshot remains published." }
  }
}

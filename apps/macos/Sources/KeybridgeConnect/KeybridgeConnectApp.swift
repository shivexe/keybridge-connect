import AppKit
import SwiftUI

@main struct KeybridgeConnectApp: App {
  @NSApplicationDelegateAdaptor(KeybridgeAppDelegate.self) private var delegate
  @StateObject private var coordinator = Coordinator()
  var body: some Scene {
    WindowGroup("Keybridge Connect") {
      ContentView(coordinator: coordinator, sharing: coordinator.sharing)
        .frame(minWidth: 820, minHeight: 600)
        .onAppear { delegate.coordinator = coordinator }
    }
    .defaultSize(width: 900, height: 650)
    .commands { CommandGroup(replacing: .newItem) {} }
  }
}

struct ContentView: View {
  @ObservedObject var coordinator: Coordinator
  @ObservedObject var sharing: Sharing
  @State private var section = "Overview"
  @State private var showPairing = false
  @State private var confirmRevoke = false
  @State private var removing: String?
  @State private var search = ""
  private var unlocked: Bool { coordinator.vault.state != nil }
  private var phone: String? { sharing.phoneName }
  private var attention: Bool {
    ["cleanup_blocked", "integrity_failure", "awaiting_authentication", "cancelled"].contains(coordinator.phase)
  }
  private var title: String {
    if coordinator.phase == "cleanup_blocked" { return "Finish cleaning up" }
    if coordinator.busy { return "Syncing your passwords" }
    if attention { return "Sync needs your attention" }
    if phone == nil { return "Pair your phone to get started" }
    if coordinator.pendingAction { return "A sync reminder is ready" }
    if sharing.status == "synced" && !coordinator.records.isEmpty { return "You’re up to date" }
    if coordinator.phase == "pending_delivery" { return "Ready for your phone" }
    return "Ready to sync"
  }
  var body: some View {
    HStack(spacing: 0) {
      if unlocked { sidebar.frame(width: 205); Divider() }
      VStack(spacing: 0) {
        HStack {
          Text(unlocked ? section : "Keybridge Connect").font(.system(size: 14, weight: .semibold))
          Spacer()
          if unlocked {
            Button { Task { await coordinator.lock() } } label: { Image(systemName: "lock") }
              .buttonStyle(.plain).help("Lock Keybridge").accessibilityLabel("Lock Keybridge")
          }
        }.padding(.horizontal, 28).frame(height: 54)
        Divider()
        if !unlocked { locked }
        else if section == "Passwords" { passwords }
        else if section == "Settings" { settings }
        else { overview }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(Color(red: 0.12, green: 0.42, blue: 0.82))
    .onTapGesture { coordinator.touch() }
    .onChange(of: unlocked) { _, value in if !value { showPairing = false } }
    .sheet(isPresented: $showPairing, onDismiss: { sharing.cancelInvitation() }) {
      PairingView(coordinator: coordinator, sharing: sharing)
    }
    .alert("Disconnect your phone?", isPresented: $confirmRevoke) {
      Button("Cancel", role: .cancel) {}
      Button("Disconnect", role: .destructive) {
        do { try sharing.revoke() } catch { coordinator.detail = "Couldn’t disconnect. Please try again." }
      }
    } message: { Text("Future sync stops. Passwords already saved on the phone remain available there.") }
    .alert("Remove this saved password?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
      Button("Cancel", role: .cancel) { removing = nil }
      Button("Remove", role: .destructive) { if let id = removing { coordinator.remove(id) }; removing = nil }
    } message: { Text("It will be removed from your phone on the next sync. Apple Passwords won’t change.") }
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 9) {
        KeybridgeMark(size: 36)
        Text("Keybridge").font(.system(size: 19, weight: .semibold))
      }.padding(.horizontal, 8).padding(.vertical, 20)
      forEachSection
      Spacer()
      Label("Stored on your devices", systemImage: "lock.shield")
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
    }.padding(12).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
  }
  private var forEachSection: some View {
    ForEach([("Overview", "arrow.triangle.2.circlepath"), ("Passwords", "key"), ("Settings", "slider.horizontal.3")], id: \.0) { item in
      Button { section = item.0 } label: {
        Label(item.0, systemImage: item.1).font(.system(size: 13, weight: section == item.0 ? .semibold : .regular))
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
          .background(section == item.0 ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
      }.buttonStyle(.plain)
    }
  }
  private var locked: some View {
    LockedCompanionView(
      detail: coordinator.phase == "cleanup_blocked" || (coordinator.phase == "locked"
        && coordinator.detail != "Unlock Keybridge Connect to begin." && !coordinator.detail.hasPrefix("Locked.")) ? coordinator.detail : "",
      cleanup: coordinator.phase == "cleanup_blocked", unlock: { coordinator.unlock() },
      recover: { Task { await coordinator.recover() } })
  }
  private var overview: some View {
    SyncOverview(title: title,
      detail: phone == nil && !attention && !coordinator.busy
        ? "Open Keybridge on your phone and scan this Mac’s pairing code."
        : coordinator.phase == "ready" && !coordinator.pendingAction ? "Sync when you change a password on your Mac. Open Keybridge on your phone to receive it." : coordinator.detail,
      phone: phone, count: coordinator.records.count, busy: coordinator.busy,
      attention: attention, delivered: sharing.status == "synced" && !coordinator.records.isEmpty,
      receipt: (coordinator.vault.state?["receipts"] as? [Object])?.compactMap { $0["confirmedAt"] as? Int }.max().map { Date(timeIntervalSince1970: Double($0)) },
      actionTitle: coordinator.phase == "cleanup_blocked" ? "Finish cleanup" : phone == nil ? "Pair your phone" : coordinator.busy ? "Syncing…" : "Sync now",
      action: {
        if coordinator.phase == "cleanup_blocked" { Task { await coordinator.recover() } }
        else if phone == nil { showPairing = true }
        else { coordinator.syncNow() }
      }, cancel: { coordinator.cancel() }, passwords: { section = "Passwords" }, pair: { section = "Settings" })
  }
  private var passwords: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Saved passwords").font(.system(size: 26, weight: .semibold))
      Text("Manage your passwords in Apple Passwords. Changes appear here after you sync.").foregroundStyle(.secondary)
      TextField("Search passwords", text: $search).textFieldStyle(.roundedBorder)
      if coordinator.records.isEmpty {
        ContentUnavailableView("No passwords synced yet", systemImage: "key", description: Text("Pair your phone, then choose Sync now from Overview."))
      } else {
        List {
          ForEach(coordinator.records.filter {
            search.isEmpty || [$0["title"] as? String ?? "", $0["username"] as? String ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
          }, id: \.recordID) { record in
            HStack(spacing: 14) {
              Image(systemName: "key").foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 4) {
                Text(record["title"] as? String ?? "").fontWeight(.medium)
                Text(record["username"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if record["state"] as? String != "active" {
                Text("Needs review").font(.caption).foregroundStyle(.orange)
                Button("Remove") { removing = record["id"] as? String }.disabled(coordinator.busy)
              } else { Text("••••••••").foregroundStyle(.secondary) }
            }.padding(.vertical, 7)
          }
        }.listStyle(.plain)
      }
    }.padding(28)
  }
  private var settings: some View {
    Form {
      Section("Phone") {
        LabeledContent("Paired device", value: phone ?? "No phone paired")
        Button(phone == nil ? "Pair your phone" : "Pair a different phone") { showPairing = true }.disabled(coordinator.busy)
        if phone != nil { Button("Disconnect phone", role: .destructive) { confirmRevoke = true }.disabled(coordinator.busy) }
      }
      Section("Sync") {
        Picker("Passwords to sync", selection: $coordinator.intent) {
          Text("All exportable passwords").tag(PasswordExportAutomation.Intent.full)
          Text("Selected in Apple Passwords").tag(PasswordExportAutomation.Intent.selected)
          #if DEBUG
          Text("Test login only (keybridge.invalid)").tag(PasswordExportAutomation.Intent.dummy)
          #endif
        }.disabled(coordinator.busy)
        Picker("Remind me to sync", selection: Binding(get: { coordinator.schedule }, set: { coordinator.updateSchedule($0) })) {
          Text("Off").tag(0); Text("Every 15 minutes").tag(900); Text("Hourly").tag(3600); Text("Daily").tag(86400); Text("Weekly").tag(604800)
        }
        Text("Apple may require your authentication. Reminders appear in Keybridge while it’s open and never wake or unlock your Mac.").font(.caption).foregroundStyle(.secondary)
      }
      Section("Apple Passwords access") {
        Text("Keybridge uses Accessibility to start Apple’s export for you. Exported files stay in an encrypted temporary volume and are removed before syncing.").font(.callout).foregroundStyle(.secondary)
        Button("Open Accessibility settings") {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
      }
      Section {
        Text("Keybridge Connect 0.1.5").font(.caption).foregroundStyle(.secondary)
        Text("Passkeys, verification codes and Wi-Fi passwords aren’t included. Apple Passwords remains your Mac password manager.").font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }
}

extension Dictionary where Key == String, Value == Any {
  var recordID: String { self["id"] as? String ?? "" }
}

@MainActor final class KeybridgeAppDelegate: NSObject, NSApplicationDelegate {
  weak var coordinator: Coordinator?
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let url = Bundle.main.url(forResource: "Keybridge", withExtension: "icns"),
      let icon = NSImage(contentsOf: url) {
      NSApplication.shared.applicationIconImage = icon
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let coordinator else { return .terminateNow }
    Task {
      await coordinator.lock()
      sender.reply(toApplicationShouldTerminate: coordinator.phase != "cleanup_blocked")
    }
    return .terminateLater
  }
}

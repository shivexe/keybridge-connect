import SwiftUI

struct PairingView: View {
  @ObservedObject var coordinator: Coordinator
  @ObservedObject var sharing: Sharing
  @Environment(\.dismiss) private var dismiss
  @State private var networkOptions = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Pair your phone").font(.system(size: 20, weight: .semibold))
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(24)
      Divider()
      TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack(spacing: 18) {
          if coordinator.preparingPair {
            ProgressView(); Text("Preparing your pairing code…").foregroundStyle(.secondary)
          } else if let error = coordinator.pairingError {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Check your connection").font(.title2.bold())
            Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Try again") { Task { await coordinator.pair() } }.buttonStyle(CompanionActionStyle())
          } else if sharing.rejected {
            Text("Pairing declined").font(.title2.bold())
            Text("Your existing connection hasn’t changed.").foregroundStyle(.secondary)
            Button("Create a new code") { Task { await coordinator.pair() } }
          } else if sharing.response != nil {
            Image(systemName: sharing.phoneName != nil && sharing.status == "synced" ? "checkmark.circle.fill" : "iphone")
              .font(.system(size: 44)).foregroundStyle(.tint)
            Text(sharing.phoneName != nil && sharing.status == "synced" ? "Your phone is paired" : "Finishing on your phone").font(.title2.bold())
            Text("Keep Keybridge open on your phone. Once connected, choose Sync now on this Mac.")
              .foregroundStyle(.secondary).multilineTextAlignment(.center)
          } else if let invitation = sharing.invitation,
            (invitation["expiresAt"] as? Int ?? 0) <= Int(context.date.timeIntervalSince1970) {
            Image(systemName: "clock").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("This code has expired").font(.title2.bold())
            Button("Create a new code") { Task { await coordinator.pair() } }.buttonStyle(CompanionActionStyle())
          } else if let code = sharing.comparison {
            Text("Compare the codes").font(.title2.bold())
            Text(sharing.request?["deviceName"] as? String ?? "Your Android phone").foregroundStyle(.secondary)
            Text(code).font(.system(size: 48, weight: .medium, design: .monospaced)).textSelection(.enabled).padding(.vertical, 16)
            Text("Only approve if your phone shows this exact code.").foregroundStyle(.secondary)
            HStack(spacing: 14) {
              Button("Decline") { approve(false) }
              Button("Codes match — approve") { approve(true) }.buttonStyle(CompanionActionStyle())
            }.controlSize(.large)
          } else if let invitation = sharing.invitation {
            Text("Scan with Keybridge on Android").font(.system(size: 19, weight: .semibold))
            PairingCode(invitation: invitation)
            Text("Connect your phone to the same Wi-Fi as this Mac,\nthen tap Scan pairing code in Keybridge.")
              .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(3)
            let remaining = max(0, (invitation["expiresAt"] as? Int ?? 0) - Int(context.date.timeIntervalSince1970))
            Text("Code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
              .font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        DisclosureGroup("Network options", isExpanded: $networkOptions) {
          VStack(alignment: .leading, spacing: 10) {
            Picker("Connection", selection: $coordinator.interface) {
              ForEach(coordinator.networks) { network in
                Text("\(network.name) · \(network.address)").tag(network.address)
              }
            }.disabled(sharing.comparison != nil || coordinator.preparingPair)
            HStack {
              Button("Refresh networks") { coordinator.discoverNetworks() }
              Button("Use this network") { Task { await coordinator.pair() } }
                .disabled(sharing.comparison != nil || coordinator.preparingPair)
            }
            if coordinator.vault.state?["staged"] != nil {
              Button("Cancel pending connection") {
                do { try sharing.cancelReplacement(); Task { await coordinator.pair() } }
                catch { coordinator.pairingError = "Couldn’t cancel the pending connection. Please try again." }
              }
            }
          }.padding(.top, 10)
        }
      }.padding(20)
    }.frame(width: 620, height: 710)
      .task { await coordinator.pair() }
  }
  private func approve(_ allow: Bool) {
    do { try sharing.approve(allow); coordinator.touch() }
    catch { coordinator.pairingError = "This pairing request expired. Create a new code and scan it again." }
  }
}

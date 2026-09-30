import SwiftUI

struct LockedCompanionView: View {
  let detail: String
  let cleanup: Bool
  let unlock: () -> Void
  let recover: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      Spacer()
      VStack(alignment: .leading, spacing: 20) {
        KeybridgeMark(size: 72)
        VStack(alignment: .leading, spacing: 10) {
          Text("Your passwords.\nOn both devices.").font(.system(size: 32, weight: .semibold))
          Text("Unlock to sync Apple Passwords with your Android phone.\nYour passwords stay encrypted on your devices.")
            .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
        }
        Button(action: cleanup ? recover : unlock) {
          Text(cleanup ? "Finish cleanup" : "Unlock Keybridge").frame(minWidth: 160)
        }.buttonStyle(CompanionActionStyle()).controlSize(.large)
        if !detail.isEmpty {
          Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }.frame(width: 390, alignment: .leading)
      Spacer()
      Label("Encrypted on your devices", systemImage: "lock.shield")
        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 28)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct SyncOverview: View {
  let title: String
  let detail: String
  let phone: String?
  let count: Int
  let busy: Bool
  let attention: Bool
  let delivered: Bool
  let receipt: Date?
  let actionTitle: String
  let action: () -> Void
  let cancel: () -> Void
  let passwords: () -> Void
  let pair: () -> Void
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Your passwords").font(.system(size: 28, weight: .semibold))
          Text(phone == nil ? "Connect your phone to get started." : "Apple Passwords, available on \(phone!).")
            .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        VStack(spacing: 0) {
          device("Apple Passwords", subtitle: "Source on this Mac", symbol: "laptopcomputer")
          HStack {
            Image(systemName: "arrow.down").font(.system(size: 13, weight: .medium))
              .frame(width: 46).foregroundStyle(.secondary)
            Rectangle().fill(.quaternary).frame(height: 1)
          }.padding(.horizontal, 20)
          device(phone ?? "Connect your Android phone",
            subtitle: phone == nil ? "Pair once over your Wi-Fi" : "Passwords available offline after syncing", symbol: "iphone")
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
          .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 0.5))
        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: attention ? "exclamationmark.circle" : delivered ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
              .font(.system(size: 21)).foregroundStyle(attention ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 7) {
              Text(title).font(.system(size: 17, weight: .semibold))
              Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
              if delivered, let receipt {
                Text("Confirmed by your phone \(receipt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.system(size: 11)).foregroundStyle(.secondary)
              }
            }
          }
          HStack(spacing: 12) {
            Button(action: action) { Text(actionTitle).frame(minWidth: 116) }
              .buttonStyle(CompanionActionStyle()).controlSize(.large).disabled(busy)
            if busy { ProgressView().controlSize(.small); Button("Cancel", action: cancel) }
          }.padding(.leading, 33)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
          .background((attention ? Color.orange : Color.accentColor).opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
          .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder((attention ? Color.orange : Color.accentColor).opacity(0.15)))
        Divider()
        HStack {
          Button(action: passwords) {
            Label("\(count) saved passwords", systemImage: "key.horizontal")
          }.buttonStyle(.plain)
          Spacer()
          if phone != nil { Button("Manage connection", action: pair).buttonStyle(.link) }
        }.font(.system(size: 12)).foregroundStyle(.secondary)
      }.padding(32).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
    }
  }
  private func device(_ title: String, subtitle: String, symbol: String) -> some View {
    HStack(spacing: 16) {
      Image(systemName: symbol).font(.system(size: 28, weight: .light)).frame(width: 46, height: 46)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }.padding(20)
  }
}

struct CompanionActionStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 13, weight: .semibold))
      .foregroundStyle(enabled ? Color.white : Color.secondary)
      .padding(.horizontal, 18).frame(minHeight: 36)
      .background(enabled ? Color(red: 0.12, green: 0.42, blue: 0.82).opacity(configuration.isPressed ? 0.8 : 1)
        : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
  }
}

struct KeybridgeMark: View {
  let size: CGFloat
  var body: some View {
    Group {
      if let url = Bundle.main.url(forResource: "Keybridge", withExtension: "icns"),
        let icon = NSImage(contentsOf: url) {
        Image(nsImage: icon).resizable().interpolation(.high)
      } else {
        Image(systemName: "key.horizontal.fill").font(.system(size: size * 0.4, weight: .semibold))
          .foregroundStyle(.white).frame(width: size, height: size)
          .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: size * 0.22))
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}

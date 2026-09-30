import Darwin
import Foundation

struct PairingNetwork: Identifiable, Equatable {
  let address: String
  let interface: String
  let priority: Int
  var id: String { address }
  var name: String { priority == 0 || priority == 2 ? "Local network" : "Private VPN" }

  static func candidate(interface: String, address: String) -> PairingNetwork? {
    guard Wire.privateIP(address), !address.hasPrefix("127."), address != "::1",
      !address.hasPrefix("169.254."), !address.lowercased().hasPrefix("fe80:"),
      !["lo", "awdl", "llw", "p2p", "bridge", "vmnet", "docker", "vbox", "tap", "veth"].contains(where: interface.hasPrefix)
    else { return nil }
    let vpn = ["utun", "tun", "tailscale", "wg"].contains(where: interface.hasPrefix)
      || address.hasPrefix("100.")
    return PairingNetwork(address: address, interface: interface,
      priority: (vpn ? 1 : 0) + (address.contains(":") ? 2 : 0))
  }

  static func discover() -> [PairingNetwork] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return [] }
    defer { freeifaddrs(interfaces) }
    var found: [PairingNetwork] = []
    var current = interfaces
    while let item = current {
      defer { current = item.pointee.ifa_next }
      guard let socket = item.pointee.ifa_addr,
        item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
        item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
        [UInt8(AF_INET), UInt8(AF_INET6)].contains(socket.pointee.sa_family)
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
        let network = candidate(interface: String(cString: item.pointee.ifa_name), address: String(cString: host)),
        !found.contains(where: { $0.address == network.address }) else { continue }
      found.append(network)
    }
    return found.sorted { ($0.priority, $0.interface, $0.address) < ($1.priority, $1.interface, $1.address) }
  }
}

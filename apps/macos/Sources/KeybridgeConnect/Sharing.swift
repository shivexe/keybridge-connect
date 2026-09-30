import CryptoKit
import Foundation

@MainActor final class Sharing: ObservableObject {
  let vault: MacVault
  @Published var status = "ready"
  @Published var invitation: Object?
  @Published var comparison: String?
  @Published var request: Object?
  @Published var response: Object?
  var bound: Data?
  @Published var rejected = false
  var transport: TLSServer?
  @Published var url: String?
  private var rates: [String: [Int]] = [:]
  init(_ vault: MacVault) { self.vault = vault }
  var time: Int { Int(Date().timeIntervalSince1970) }
  func current() throws -> Object {
    guard let state = vault.state else { throw ProtocolError.locked }
    return state
  }
  func start(_ ip: String, port: Int = 49444) async throws {
    try Wire.require(Wire.privateIP(ip))
    let state = try current()
    let server = try TLSServer(
      certificate: Wire.binary(state["certificate"]), privateKey: Wire.string(state, "privateKey")
    ) { [weak self] path, bytes in
      await MainActor.run {
        do {
          guard let self else { return (503, ["error": "locked"]) }
          return try self.route(path, bytes)
        } catch { return (400, ["error": "request_rejected"]) }
      }
    }
    try await server.start(ip: ip, port: port)
    transport = server
    url = "https://\(ip.contains(":") ? "[\(ip)]" : ip):\(port)"
  }
  func stop() async {
    await transport?.stop()
    transport = nil
    url = nil
    invitation = nil
    request = nil
    response = nil
    bound = nil
    comparison = nil
  }
  var phoneName: String? { (vault.state?["active"] as? Object)?["deviceName"] as? String }
  func cancelInvitation() {
    invitation = nil
    request = nil
    comparison = nil
    response = nil
    bound = nil
    rejected = false
  }
  func cancelReplacement() throws {
    var state = try current()
    state.removeValue(forKey: "staged")
    try vault.save(state)
    cancelInvitation()
  }
  func invite() throws {
    let state = try current()
    try Wire.require(url != nil)
    if let staged = state["staged"] as? Object {
      if try Wire.int(staged, "expiresAt") > time { throw ProtocolError.receipt }
      var next = state
      next.removeValue(forKey: "staged")
      try vault.save(next)
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Wire.binary(state["seed"], 32))
    invitation = [
      "version": 1, "vaultId": state["vaultId"]!, "pairId": UUID().uuidString.lowercased(),
      "secret": try Wire.random(32).base64EncodedString(),
      "publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
      "certificateSha256": try Wire.digest(Wire.binary(state["certificate"])),
      "expiresAt": time + 300, "desktopName": "Keybridge Mac", "url": url!,
    ]
    request = nil
    response = nil
    bound = nil
    comparison = nil
    rejected = false
  }
  func approve(_ allow: Bool) throws {
    guard let q = invitation, let request else { throw ProtocolError.invalid }
    try Wire.require(Wire.int(q, "expiresAt") > time)
    if !allow {
      rejected = true
      return
    }
    if response != nil { return }
    var state = try current()
    let device: Object = [
      "deviceId": request["deviceId"]!, "deviceName": request["deviceName"]!,
      "syncKey": try Wire.random(32).base64EncodedString(), "expiresAt": time + 600,
    ]
    state["staged"] = device
    try vault.save(state)
    response = try Wire.seal(
      [
        "version": 1, "vaultId": state["vaultId"]!, "deviceId": device["deviceId"]!,
        "syncKey": device["syncKey"]!, "desktopName": q["desktopName"]!,
      ], SymmetricKey(data: Wire.binary(q["secret"], 32)),
      Wire.aad("pair-response", Wire.string(state, "vaultId"), Wire.string(q, "pairId")))
  }
  func revoke() throws {
    var state = try current()
    state.removeValue(forKey: "active")
    state.removeValue(forKey: "staged")
    state["deliveries"] = [Object]()
    state["receipts"] = [Object]()
    try vault.save(state)
    invitation = nil
    request = nil
    response = nil
    status = "pending_delivery"
  }
  func publish(_ records: [Object]) throws {
    var state = try current()
    if try Wire.data(["records": records]) == Wire.data(["records": state["records"]!]),
      try Wire.int(state, "generation") > 0
    {
      status = delivered(state) ? "synced" : "pending_delivery"
      return
    }
    state["records"] = records
    state["generation"] = try Wire.int(state, "generation") + 1
    let body: Object = [
      "version": 1, "vaultId": state["vaultId"]!, "generation": state["generation"]!,
      "createdAt": time, "source": "macos", "records": records,
    ]
    try Wire.snapshot(body)
    let bytes = try Wire.data(body)
    state["body"] = bytes.base64EncodedString()
    state["digest"] = Wire.digest(bytes)
    try vault.save(state)
    status = "pending_delivery"
  }
  func delivered(_ state: Object) -> Bool {
    let active = state["active"] as? Object
    return (state["receipts"] as? [Object] ?? []).contains {
      ($0["deviceId"] as? String) == (active?["deviceId"] as? String)
        && ($0["generation"] as? Int) == (state["generation"] as? Int)
        && ($0["snapshotSha256"] as? String) == (state["digest"] as? String)
    }
  }
  func rate(_ id: String, _ limit: Int) -> Bool {
    rates[id] = (rates[id] ?? []).filter { $0 > time - 60 }
    guard rates[id]!.count < limit else { return false }
    rates[id]!.append(time)
    return true
  }
  func route(_ path: String, _ bytes: Data) throws -> (Int, Object) {
    let box = try Wire.parse(bytes, limit: 256 * 1024)
    var state = try current()
    let vaultId = try Wire.string(state, "vaultId")
    if path.hasPrefix("/v1/pair/") {
      guard rate("pair", 30) else { return (429, ["error": "rate_limited"]) }
      guard let q = invitation, try Wire.int(q, "expiresAt") > time,
        path == "/v1/pair/\(try Wire.string(q,"pairId"))"
      else { return (410, ["error": "expired"]) }
      if rejected { return (403, ["error": "rejected"]) }
      let p = try Wire.open(
        box, SymmetricKey(data: Wire.binary(q["secret"], 32)),
        Wire.aad("pair-request", vaultId, Wire.string(q, "pairId")))
      try Wire.require(
        Wire.int(p, "version") == 1 && Wire.string(p, "vaultId") == vaultId
          && Wire.id(Wire.string(p, "deviceId")) && Wire.string(p, "deviceName").count <= 80)
      let nonce = try Wire.binary(p["clientNonce"], 32)
      if let bound, bound != bytes { return (403, ["error": "bound"]) }
      bound = bytes
      request = p
      let hash = SHA256.hash(data: try Wire.binary(q["secret"], 32) + nonce)
      let n = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      comparison = String(format: "%06u", n % 1_000_000)
      return response.map { (200, $0) } ?? (202, ["status": "pending"])
    }
    try Wire.require(["/v1/sync", "/v1/ack"].contains(path))
    let id = try Wire.string(box, "deviceId")
    try Wire.require(Wire.id(id))
    var device = state["active"] as? Object
    if let staged = state["staged"] as? Object, staged["deviceId"] as? String == id,
      try Wire.int(staged, "expiresAt") > time
    {
      device = staged
    }
    guard let device, device["deviceId"] as? String == id else {
      return (403, ["error": "revoked"])
    }
    guard rate(id, 60) else { return (429, ["error": "rate_limited"]) }
    let kind = path == "/v1/sync" ? "sync" : "ack"
    let root = try Wire.binary(device["syncKey"], 32)
    let p = try Wire.open(
      box, Wire.derive(root, vaultId, id, "c2s"), Wire.aad("\(kind)-request", vaultId, id))
    try Wire.require(
      Wire.int(p, "version") == 1 && Wire.string(p, "vaultId") == vaultId
        && Wire.string(p, "deviceId") == id)
    let requestId = try Wire.string(p, "requestId")
    _ = try Wire.binary(requestId, 32)
    var result: Object
    if kind == "sync" {
      let generation = try Wire.int(state, "generation")
      guard generation > 0 else { return (409, ["error": "no_snapshot"]) }
      let last = try Wire.int(p, "lastGeneration")
      try Wire.require(
        last <= generation
          && (last != generation || Wire.string(p, "lastDigest") == Wire.string(state, "digest")))
      var deliveries = (state["deliveries"] as? [Object] ?? []).filter {
        ($0["expiresAt"] as? Int ?? 0) > time
          && !(($0["deviceId"] as? String) == id && ($0["requestId"] as? String) == requestId)
      }
      while deliveries.filter({ $0["deviceId"] as? String == id }).count >= 32 {
        deliveries.remove(at: deliveries.firstIndex { $0["deviceId"] as? String == id }!)
      }
      deliveries.append([
        "deviceId": id, "requestId": requestId, "generation": generation,
        "snapshotSha256": state["digest"]!, "expiresAt": time + 86400,
      ])
      state["deliveries"] = deliveries
      try vault.save(state)
      result =
        last == generation
        ? [
          "version": 1, "status": "unchanged", "requestId": requestId, "generation": generation,
          "snapshotSha256": state["digest"]!,
        ]
        : try Wire.signed(
          Wire.string(state, "body"), request: requestId, seed: Wire.binary(state["seed"], 32))
      status = "awaiting_receipt"
    } else {
      try Wire.require(Wire.string(p, "status") == "committed" && Wire.int(p, "generation") > 0)
      _ = try Wire.binary(p["snapshotSha256"], 32)
      func matches(_ d: Object) -> Bool {
        ["deviceId", "requestId", "generation", "snapshotSha256"].allSatisfy {
          String(describing: d[$0] ?? "") == String(describing: p[$0] ?? "")
        }
      }
      try Wire.require(
        (state["deliveries"] as? [Object] ?? []).contains {
          matches($0) && ($0["expiresAt"] as? Int ?? 0) > time
        } || (state["receipts"] as? [Object] ?? []).contains(where: matches))
      if let staged = state["staged"] as? Object, staged["deviceId"] as? String == id {
        var active = staged
        active.removeValue(forKey: "expiresAt")
        state["active"] = active
        state.removeValue(forKey: "staged")
        state["deliveries"] = (state["deliveries"] as? [Object] ?? []).filter {
          $0["deviceId"] as? String == id
        }
      }
      var receipts = (state["receipts"] as? [Object] ?? []).filter {
        $0["deviceId"] as? String != id
      }
      var receipt = p
      receipt["confirmedAt"] = time
      receipts.append(receipt)
      state["receipts"] = receipts
      try vault.save(state)
      result = p
      result["status"] = "recorded"
      status = delivered(state) ? "synced" : "pending_delivery"
    }
    return (
      200,
      try Wire.seal(
        result, Wire.derive(root, vaultId, id, "s2c"), Wire.aad("\(kind)-response", vaultId, id))
    )
  }
}

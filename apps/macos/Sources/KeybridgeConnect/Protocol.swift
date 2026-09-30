import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

typealias Object = [String: Any]
enum ProtocolError: Error { case invalid, limit, locked, receipt, stale }
enum Wire {
  static let maximum = 9_007_199_254_740_991
  static func require(_ value: Bool) throws { if !value { throw ProtocolError.invalid } }
  static func data(_ value: Object) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
  }
  static func parse(_ bytes: Data, limit: Int = 32 * 1024 * 1024) throws -> Object {
    try require(bytes.count <= limit)
    var scanner = StrictJSON(bytes: Array(bytes))
    try scanner.value(depth: 0)
    scanner.space()
    try require(scanner.index == scanner.bytes.count)
    guard let value = try JSONSerialization.jsonObject(with: bytes) as? Object else {
      throw ProtocolError.invalid
    }
    return value
  }
  static func string(_ value: Object, _ key: String) throws -> String {
    guard let s = value[key] as? String else { throw ProtocolError.invalid }
    return s
  }
  static func int(_ value: Object, _ key: String) throws -> Int {
    guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
      n.doubleValue >= 0, n.doubleValue <= Double(maximum), n.doubleValue == Double(n.int64Value)
    else { throw ProtocolError.invalid }
    return n.intValue
  }
  static func binary(_ value: Any?, _ length: Int? = nil) throws -> Data {
    guard let s = value as? String, s.count <= 32 * 1024 * 1024, let d = Data(base64Encoded: s),
      d.base64EncodedString() == s, length == nil || d.count == length
    else { throw ProtocolError.invalid }
    return d
  }
  static func id(_ s: String) -> Bool {
    s == s.lowercased() && s.count == 36 && UUID(uuidString: s) != nil
  }
  static func random(_ size: Int) throws -> Data {
    var d = Data(count: size)
    let code = d.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!)
    }
    try require(code == errSecSuccess)
    return d
  }
  static func digest(_ d: Data) -> String { Data(SHA256.hash(data: d)).base64EncodedString() }
  static func aad(_ type: String, _ vault: String, _ id: String) -> Data {
    Data("keybridge/v1/\(type)/\(vault)/\(id)".utf8)
  }
  static func derive(_ root: Data, _ vault: String, _ device: String, _ direction: String)
    -> SymmetricKey
  {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: root),
      salt: Data("keybridge/v1/\(vault)/\(device)".utf8),
      info: Data("keybridge/v1/\(direction)".utf8), outputByteCount: 32)
  }
  static func seal(_ plain: Object, _ key: SymmetricKey, _ context: Data) throws -> Object {
    let b = try AES.GCM.seal(data(plain), using: key, authenticating: context)
    return [
      "nonce": b.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
      "ciphertext": b.ciphertext.base64EncodedString(), "tag": b.tag.base64EncodedString(),
    ]
  }
  static func open(_ box: Object, _ key: SymmetricKey, _ context: Data) throws -> Object {
    let b = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: binary(box["nonce"], 12)), ciphertext: binary(box["ciphertext"]),
      tag: binary(box["tag"], 16))
    return try parse(AES.GCM.open(b, using: key, authenticating: context))
  }
  static func signed(_ body: String, request: String, seed: Data) throws -> Object {
    let payload = try data([
      "requestId": request, "snapshotBodyBase64": body, "snapshotSha256": digest(binary(body)),
    ]).base64EncodedString()
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    return [
      "payload": payload,
      "signature": try key.signature(for: Data("keybridge.snapshot.v1\n\(payload)".utf8))
        .base64EncodedString(),
    ]
  }
  static func snapshot(_ s: Object) throws {
    try require(int(s, "version") == 1 && id(string(s, "vaultId")) && int(s, "generation") > 0)
    _ = try int(s, "createdAt")
    try require(["linux", "macos"].contains(string(s, "source")))
    guard let records = s["records"] as? [Object], records.count <= 10000 else {
      throw ProtocolError.limit
    }
    var ids = Set<String>()
    for record in records {
      let id = try string(record, "id")
      try require(Self.id(id) && ids.insert(id).inserted && data(record).count <= 65536)
      for k in ["title", "username", "password", "notes"] { _ = try string(record, k) }
      try require(["active", "missing", "conflict"].contains(string(record, "state")))
      guard let urls = record["urls"] as? [String], urls.count <= 100,
        urls.allSatisfy({ $0.utf8.count <= 8192 })
      else { throw ProtocolError.invalid }
    }
    try require(data(s).count <= 8 * 1024 * 1024)
  }
  static func privateIP(_ ip: String) -> Bool {
    var v4 = in_addr()
    if inet_pton(AF_INET, ip, &v4) == 1 {
      let n = UInt32(bigEndian: v4.s_addr)
      return n >> 24 == 10 || n >> 20 == 0xac1 || n >> 16 == 0xc0a8
        || n & 0xffc0_0000 == 0x6440_0000
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, ip, &v6) == 1 {
      return withUnsafeBytes(of: &v6) { $0[0] & 0xfe == 0xfc }
    }
    return false
  }
}
struct StrictJSON {
  let bytes: [UInt8]
  var index = 0
  mutating func space() {
    while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }
  mutating func string() throws -> String {
    let start = index
    index += 1
    var ended = false
    while index < bytes.count {
      let c = bytes[index]
      index += 1
      if c == 92 {
        try Wire.require(index < bytes.count)
        index += 1
      } else if c == 34 {
        ended = true
        break
      }
    }
    try Wire.require(ended)
    let data = Data(bytes[start..<index])
    guard
      let s = try JSONSerialization.jsonObject(with: Data([91]) + data + Data([93])) as? [String],
      s.count == 1
    else { throw ProtocolError.invalid }
    return s[0]
  }
  mutating func value(depth: Int) throws {
    try Wire.require(depth <= 24)
    space()
    try Wire.require(index < bytes.count)
    if bytes[index] == 34 {
      _ = try string()
      return
    }
    if bytes[index] == 123 || bytes[index] == 91 {
      let object = bytes[index] == 123
      let close: UInt8 = object ? 125 : 93
      index += 1
      space()
      var keys = Set<String>()
      if index < bytes.count && bytes[index] == close {
        index += 1
        return
      }
      while true {
        space()
        try Wire.require(index < bytes.count)
        if object {
          try Wire.require(bytes[index] == 34)
          let key = try string()
          try Wire.require(keys.insert(key).inserted)
          space()
          try Wire.require(index < bytes.count && bytes[index] == 58)
          index += 1
        }
        try value(depth: depth + 1)
        space()
        try Wire.require(index < bytes.count)
        let next = bytes[index]
        index += 1
        if next == close { return }
        try Wire.require(next == 44)
      }
    }
    let start = index
    while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
    let token = String(decoding: bytes[start..<index], as: UTF8.self)
    if ["true", "false", "null"].contains(token) { return }
    try Wire.require(
      token.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil
        && Int(token).map { $0 <= Wire.maximum } == true)
  }
}

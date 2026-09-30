import Crypto
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import SwiftASN1
import X509

enum VaultFailure: Error { case keychain(OSStatus) }

@MainActor final class MacVault {
  let root: URL
  var state: Object?
  private var key: CryptoKit.SymmetricKey?
  private var authentication: LAContext?
  private var unlockAttempt: UUID?
  private var lockFD: Int32 = -1
  var runtime: URL { root.appendingPathComponent("operations", isDirectory: true) }
  var archive: URL { root.appendingPathComponent("state.kbv") }
  init() {
    #if KEYBRIDGE_COMMUNITY
      let directory = "Keybridge Connect Community"
    #else
      let directory = "Keybridge Connect"
    #endif
    root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(directory, isDirectory: true)
  }
  func initialize() throws {
    for dir in [root, runtime] {
      if !FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.createDirectory(
          at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      }
      try ExportWorkspace.validateDirectory(dir)
      var mutable = dir
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try mutable.setResourceValues(values)
    }
    if lockFD < 0 {
      lockFD = open(
        root.appendingPathComponent("instance.lock").path,
        O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        throw BridgeFailure.unsafeWorkspace
      }
    }
    _ = try ExportWorkspace.recover(in: runtime)
  }
  func unlock() async throws {
    try initialize()
    let attempt = UUID()
    unlockAttempt = attempt
    defer {
      if unlockAttempt == attempt { cancelUnlock() }
    }
    #if KEYBRIDGE_COMMUNITY
      let context = LAContext()
      authentication = context
      var authError: NSError?
      guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError)
      else { throw ProtocolError.locked }
      let accepted = try await context.evaluatePolicy(
        .deviceOwnerAuthentication, localizedReason: "Unlock Keybridge Connect")
      guard accepted, unlockAttempt == attempt else { throw ProtocolError.locked }
      var query: Object = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.keybridge.connect.mac.community.vault",
        kSecAttrAccount as String: "v1", kSecUseDataProtectionKeychain as String: false,
      ]
    #else
      var query: Object = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.keybridge.connect.mac.vault",
        kSecAttrAccount as String: "v1",
        kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
      ]
    #endif
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    lookup[kSecUseOperationPrompt as String] = "Unlock Keybridge Connect"
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess {
      guard let bytes = result as? Data, bytes.count == 32 else { throw ProtocolError.invalid }
      key = CryptoKit.SymmetricKey(data: bytes)
    } else {
      guard status == errSecItemNotFound, !FileManager.default.fileExists(atPath: archive.path)
      else { throw ProtocolError.locked }
      let bytes = try Wire.random(32)
      #if KEYBRIDGE_COMMUNITY
        var access: SecAccess?
        let accessStatus = SecAccessCreate("Keybridge Connect vault" as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else {
          throw VaultFailure.keychain(accessStatus)
        }
        query[kSecValueData as String] = bytes
        query[kSecAttrAccess as String] = access
      #else
        var error: Unmanaged<CFError>?
        guard
          let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error)
        else { throw ProtocolError.locked }
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessControl as String] = access
      #endif
      let added = SecItemAdd(query as CFDictionary, nil)
      guard added == errSecSuccess else { throw VaultFailure.keychain(added) }
      key = CryptoKit.SymmetricKey(data: bytes)
    }
    do {
      if FileManager.default.fileExists(atPath: archive.path) {
        var info = stat()
        try Wire.require(
          lstat(archive.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && info.st_uid == getuid() && info.st_nlink == 1 && info.st_size <= 64 * 1024 * 1024)
        state = try Wire.open(
          Wire.parse(Data(contentsOf: archive), limit: 64 * 1024 * 1024), key!,
          Data("keybridge/v1/macos-state".utf8))
      } else {
        let tlsKey = Crypto.P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(tlsKey)
        let name = try DistinguishedName { CommonName("Keybridge Connect") }
        let start = Date().addingTimeInterval(-60)
        let certificate = try Certificate(
          version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: certKey.publicKey,
          notValidBefore: start, notValidAfter: start.addingTimeInterval(86400 * 3650),
          issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
          extensions: Certificate.Extensions {}, issuerPrivateKey: certKey)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        state = [
          "version": 1, "vaultId": UUID().uuidString.lowercased(),
          "seed": try Wire.random(32).base64EncodedString(),
          "certificate": Data(serializer.serializedBytes).base64EncodedString(),
          "privateKey": tlsKey.pemRepresentation, "records": [Object](), "generation": 0,
          "deliveries": [Object](), "receipts": [Object](),
        ]
        try save(state!)
      }
    } catch {
      lock()
      throw error
    }
  }
  func save(_ next: Object) throws {
    guard let key else { throw ProtocolError.locked }
    let data = try Wire.data(Wire.seal(next, key, Data("keybridge/v1/macos-state".utf8)))
    let temp = root.appendingPathComponent(".\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temp) }
    let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try Wire.require(fd >= 0)
    do {
      try data.withUnsafeBytes { buffer in
        var total = 0
        while total < buffer.count {
          let count = write(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
          guard count > 0 else { throw ProtocolError.invalid }
          total += count
        }
      }
      try Wire.require(fsync(fd) == 0)
      close(fd)
    } catch {
      close(fd)
      throw error
    }
    try Wire.require(rename(temp.path, archive.path) == 0)
    let dir = open(root.path, O_RDONLY | O_CLOEXEC)
    try Wire.require(dir >= 0)
    let code = fsync(dir)
    close(dir)
    try Wire.require(code == 0)
    state = next
  }
  func lock() {
    cancelUnlock()
    state = nil
    key = nil
  }
  func cancelUnlock() {
    unlockAttempt = nil
    authentication?.invalidate()
    authentication = nil
  }
}

import CryptoKit
import Darwin
import Foundation
import Security

enum BridgeFailure: String, Error {
  case unsafeWorkspace, commandFailed, invalidImage, cleanupFailed
  case invalidCSV, expectedDummyOnly, cancelled, exportTimedOut, simulatedFailure
}

/// Native probe infrastructure. No credentials or subprocess diagnostics are logged.
enum NativeCommand {
  static func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    let stdin = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = stdin
    try process.run()
    // Keep disk-image utilities from holding the UI/cleanup path indefinitely.
    let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
    let killStuckChild = DispatchWorkItem {
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: terminate)
    DispatchQueue.global().asyncAfter(deadline: .now() + 50, execute: killStuckChild)
    defer {
      terminate.cancel()
      killStuckChild.cancel()
    }
    if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
    try stdin.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw BridgeFailure.commandFailed }
    return result
  }

  static func plist(_ arguments: [String], input: Data? = nil) throws -> [String: Any] {
    let data = try run("/usr/bin/hdiutil", arguments, input: input)
    guard
      let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { throw BridgeFailure.invalidImage }
    return value
  }
}

final class ExportWorkspace {
  let directory: URL
  var image: URL { directory.appendingPathComponent("export.dmg") }
  var mount: URL { directory.appendingPathComponent("mount", isDirectory: true) }
  var csv: URL { mount.appendingPathComponent("keybridge-export.csv") }
  private let fm = FileManager.default

  init(directory: URL) { self.directory = directory }

  static func validateDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(), (info.st_mode & 0o077) == 0
    else { throw BridgeFailure.unsafeWorkspace }
  }

  static func create(in root: URL) throws -> ExportWorkspace {
    try validateDirectory(root)
    let url = root.appendingPathComponent("operation-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let workspace = ExportWorkspace(directory: url)
    do {
      var excluded = url
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try excluded.setResourceValues(values)
      // The operation directory itself is the recovery journal. No secret key is persisted.
      try Data("keybridge-encrypted-export-v1\n".utf8).write(
        to: url.appendingPathComponent("owner"), options: .withoutOverwriting)
      try FileManager.default.createDirectory(
        at: workspace.mount, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      var random = Data(count: 32)
      let result = random.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
      }
      guard result == errSecSuccess else { throw BridgeFailure.invalidImage }
      var passphrase = Data(random.base64EncodedString().utf8)
      passphrase.append(0)
      defer {
        random.resetBytes(in: 0..<random.count)
        passphrase.resetBytes(in: 0..<passphrase.count)
      }
      _ = try NativeCommand.run(
        "/usr/bin/hdiutil",
        [
          "create", "-size", "64m", "-fs", "APFS",
          "-volname", "Keybridge Temporary Export", "-encryption", "AES-256", "-stdinpass",
          "-nospotlight", workspace.image.path,
        ], input: passphrase)
      let encryption = try NativeCommand.plist(["isencrypted", "-plist", workspace.image.path])
      guard encryption["encrypted"] as? Bool == true else { throw BridgeFailure.invalidImage }
      _ = try NativeCommand.plist(
        [
          "attach", workspace.image.path, "-stdinpass", "-mountpoint",
          workspace.mount.path, "-noautoopen", "-plist",
        ], input: passphrase)
      guard try workspace.attachedImages().count == 1 else { throw BridgeFailure.invalidImage }
      guard chmod(workspace.mount.path, 0o700) == 0 else { throw BridgeFailure.unsafeWorkspace }
      try Data().write(to: workspace.mount.appendingPathComponent(".metadata_never_index"))
      return workspace
    } catch {
      // A cleanup failure takes precedence: callers must not start another export.
      try workspace.cleanup()
      throw error
    }
  }

  private func attachedImages() throws -> [[String: Any]] {
    let info = try NativeCommand.plist(["info", "-plist"])
    guard let images = info["images"] as? [[String: Any]] else { throw BridgeFailure.invalidImage }
    return images.filter { ($0["image-path"] as? String) == image.path }
  }

  func cleanup() throws {
    try Self.validateDirectory(directory)
    // Never recursively remove the mount directory. A failed detach leaves the journal for retry.
    for attached in try attachedImages() {
      guard let entities = attached["system-entities"] as? [[String: Any]],
        let device = entities.compactMap({ $0["dev-entry"] as? String }).first,
        device.hasPrefix("/dev/disk")
      else { throw BridgeFailure.cleanupFailed }
      let mountedHere = entities.contains { ($0["mount-point"] as? String) == mount.path }
      if mountedHere {
        var info = stat()
        if lstat(csv.path, &info) == 0 {
          guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
            unlink(csv.path) == 0
          else { throw BridgeFailure.cleanupFailed }
        } else if errno != ENOENT {
          throw BridgeFailure.cleanupFailed
        }
      }
      _ = try NativeCommand.run("/usr/bin/hdiutil", ["detach", device])
    }
    guard try attachedImages().isEmpty else { throw BridgeFailure.cleanupFailed }
    for name in ["export.dmg", "owner"] {
      let url = directory.appendingPathComponent(name)
      var info = stat()
      if lstat(url.path, &info) == 0 {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
          unlink(url.path) == 0
        else { throw BridgeFailure.cleanupFailed }
      } else if errno != ENOENT {
        throw BridgeFailure.cleanupFailed
      }
    }
    if rmdir(mount.path) != 0 && errno != ENOENT { throw BridgeFailure.cleanupFailed }
    guard rmdir(directory.path) == 0 else { throw BridgeFailure.cleanupFailed }
  }

  static func recover(in root: URL) throws -> Int {
    try validateDirectory(root)
    var recovered = 0
    for url in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    {
      let name = url.lastPathComponent
      guard name.hasPrefix("operation-"), UUID(uuidString: String(name.dropFirst(10))) != nil else {
        continue
      }
      try validateDirectory(url)
      let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
      guard Set(names).isSubset(of: ["owner", "export.dmg", "mount"]) else {
        throw BridgeFailure.unsafeWorkspace
      }
      // Fixed names + validated private UUID directory also recover a crash before marker creation.
      try ExportWorkspace(directory: url).cleanup()
      recovered += 1
    }
    return recovered
  }

  func readCSV() throws -> Data {
    let descriptor = open(csv.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw BridgeFailure.invalidCSV }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1, info.st_uid == getuid(), info.st_size > 0,
      info.st_size <= 16 * 1024 * 1024,
      fchmod(descriptor, 0o600) == 0
    else { throw BridgeFailure.invalidCSV }
    var data = Data(count: Int(info.st_size))
    let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
    var after = stat()
    guard count == data.count, fstat(descriptor, &after) == 0, after.st_size == info.st_size,
      after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec
    else { throw BridgeFailure.invalidCSV }
    return data
  }
}

enum DummyCSV {
  // Parse UTF-8 without trimming credentials; handle escaped quotes, commas and CRLF inside fields.
  static func rows(_ data: Data) throws -> [[String]] {
    guard let text = String(data: data, encoding: .utf8) else { throw BridgeFailure.invalidCSV }
    var bytes = Array(text.utf8)
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    var rows: [[String]] = []
    var row: [String] = []
    var field: [UInt8] = []
    var quoted = false
    var endedQuote = false
    var index = 0
    func endField() {
      row.append(String(decoding: field, as: UTF8.self))
      field.removeAll()
      endedQuote = false
    }
    while index < bytes.count {
      guard field.count <= 65536, row.count <= 64, rows.count <= 10001 else {
        throw BridgeFailure.invalidCSV
      }
      let byte = bytes[index]
      if quoted {
        if byte == 34 {
          if index + 1 < bytes.count && bytes[index + 1] == 34 {
            field.append(34)
            index += 1
          } else {
            quoted = false
            endedQuote = true
          }
        } else {
          field.append(byte)
        }
      } else if byte == 44 {
        endField()
      } else if byte == 10 || byte == 13 {
        endField()
        rows.append(row)
        row.removeAll()
        if byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 { index += 1 }
      } else if byte == 34 && field.isEmpty && !endedQuote {
        quoted = true
      } else {
        guard !endedQuote && byte != 34 else { throw BridgeFailure.invalidCSV }
        field.append(byte)
      }
      index += 1
    }
    guard !quoted else { throw BridgeFailure.invalidCSV }
    if !field.isEmpty || !row.isEmpty || endedQuote {
      endField()
      rows.append(row)
    }
    return rows
  }

  static func validate(_ data: Data) throws -> Int {
    let rows = try rows(data)
    guard rows.count == 2, let header = rows.first, Set(header).count == header.count,
      let site = header.firstIndex(of: "URL"), let password = header.firstIndex(of: "Password"),
      header.contains("Username"), rows[1].count == header.count,
      let url = URL(string: rows[1][site]), url.host?.lowercased() == "keybridge.invalid",
      !rows[1][password].isEmpty
    else { throw BridgeFailure.expectedDummyOnly }
    return 1
  }

  static let fixture = Data(
    "Title,URL,Username,Password,Notes,OTPAuth\r\nKeybridge,https://keybridge.invalid,\" dummy user \",\" dummy,\"\"password\"\" \",\"line one\r\nline two\",\r\n"
      .utf8)
}

enum EncryptedProcessing {
  static func roundTrip(_ plaintext: Data) throws -> Int {
    let count = try DummyCSV.validate(plaintext)
    let key = SymmetricKey(size: .bits256)
    let context = Data("keybridge-dummy-probe-v1".utf8)
    let encrypted = try AES.GCM.seal(plaintext, using: key, authenticating: context)
    var decrypted = try AES.GCM.open(encrypted, using: key, authenticating: context)
    defer { decrypted.resetBytes(in: 0..<decrypted.count) }
    guard decrypted == plaintext else { throw BridgeFailure.invalidCSV }
    return count
  }
}

import CryptoKit
import XCTest

@testable import KeybridgeConnect

final class ProtocolTests: XCTestCase {
  func testAutomaticNetworkSelection() {
    for address in ["8.8.8.8", "127.0.0.1", "169.254.1.2", "fe80::1", "::1"] {
      XCTAssertNil(PairingNetwork.candidate(interface: "en0", address: address))
    }
    XCTAssertNil(PairingNetwork.candidate(interface: "bridge0", address: "192.168.1.1"))
    let lan = PairingNetwork.candidate(interface: "en0", address: "192.168.29.251")!
    let vpn = PairingNetwork.candidate(interface: "utun3", address: "100.64.207.29")!
    XCTAssertLessThan(lan.priority, vpn.priority)
    XCTAssertEqual(lan.name, "Local network")
  }
  func testSharedVectors() throws {
    let url = Bundle.module.url(forResource: "protocol-vectors", withExtension: "json")!
    let v = try Wire.parse(Data(contentsOf: url))
    let root = try Wire.binary(v["root"], 32)
    let vault = try Wire.string(v, "vaultId")
    let device = try Wire.string(v, "deviceId")
    let key = Wire.derive(root, vault, device, "c2s")
    XCTAssertEqual(key.withUnsafeBytes { Data($0).base64EncodedString() }, v["c2s"] as? String)
    let opened = try Wire.open(v["envelope"] as! Object, key, Data(Wire.string(v, "aad").utf8))
    XCTAssertEqual(try Wire.data(opened), try Wire.data(v["plaintext"] as! Object))
    let signed = v["signed"] as! Object
    let publicKey = try Curve25519.Signing.PublicKey(
      rawRepresentation: Wire.binary(v["publicKey"], 32))
    let payload = try Wire.string(signed, "payload")
    XCTAssertTrue(
      try publicKey.isValidSignature(
        Wire.binary(signed["signature"], 64), for: Data("keybridge.snapshot.v1\n\(payload)".utf8)))
    XCTAssertEqual(try Wire.digest(Wire.binary(v["bodyBase64"])), v["digest"] as? String)
    XCTAssertThrowsError(try Wire.parse(Data("{\"x\":1,\"x\":2}".utf8)))
    XCTAssertThrowsError(try Wire.open(v["envelope"] as! Object, key, Data("wrong context".utf8)))
  }
  func testEncryptedWorkspaceCleanupAndRecovery() throws {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = project.appendingPathComponent(".work/mac-workspace-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { if (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true {
      try? FileManager.default.removeItem(at: root)
    } }
    let workspace = try ExportWorkspace.create(in: root)
    do {
      try DummyCSV.fixture.write(to: workspace.csv)
      XCTAssertEqual(try workspace.readCSV(), DummyCSV.fixture)
      XCTAssertEqual(try DummyCSV.validate(workspace.readCSV()), 1)
      try workspace.cleanup()
      XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.directory.path))
    } catch {
      try workspace.cleanup()
      throw error
    }
    let abandoned = try ExportWorkspace.create(in: root)
    try DummyCSV.fixture.write(to: abandoned.csv)
    XCTAssertEqual(try ExportWorkspace.recover(in: root), 1)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

}

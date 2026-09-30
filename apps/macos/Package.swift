// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "KeybridgeConnect",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "KeybridgeConnect", targets: ["KeybridgeConnect"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.91.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.15.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.3.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.6.0")
    ],
    targets: [.executableTarget(name: "KeybridgeConnect", dependencies: [
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "X509", package: "swift-certificates"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "SwiftASN1", package: "swift-asn1")
    ]), .testTarget(name: "KeybridgeConnectTests", dependencies: ["KeybridgeConnect"], resources: [.copy("protocol-vectors.json")])],
    swiftLanguageModes: [.v5]
)

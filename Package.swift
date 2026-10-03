// swift-tools-version: 6.0
import PackageDescription

let linux = TargetDependencyCondition.when(platforms: [.linux])
let crypto = Target.Dependency.product(name: "Crypto", package: "swift-crypto", condition: linux)

let package = Package(
    name: "StampdrillKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Stamp", targets: ["Stamp"]),
        .library(name: "StampdrillCore", targets: ["StampdrillCore"]),
        .executable(name: "stampdrill", targets: ["StampdrillCLI"]),
        // The same program under a shorter name; it reads argv[0], so its help matches.
        .executable(name: "stamp", targets: ["StampdrillCLI"]),
    ],
    dependencies: [
        // CryptoKit's API on Linux.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "4.0.0"),
        // WebSockets on Linux, where URLSession's libcurl backend has none.
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        // HTTP on Linux: the static SDK's libcurl can't verify certificates.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .target(name: "Stamp", dependencies: [crypto]),
        .target(name: "StampdrillCore", dependencies: [
            "Stamp", crypto,
            .product(name: "WebSocketKit", package: "websocket-kit", condition: linux),
            .product(name: "NIOSSL", package: "swift-nio-ssl", condition: linux),
            .product(name: "AsyncHTTPClient", package: "async-http-client", condition: linux),
        ]),
        .executableTarget(name: "StampdrillCLI", dependencies: ["StampdrillCore"]),
        .testTarget(name: "StampTests", dependencies: ["Stamp"]),
        .testTarget(name: "StampdrillCoreTests", dependencies: ["StampdrillCore"]),
    ]
)

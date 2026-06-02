// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PortholeProtocol",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "PortholeProtocol", targets: ["PortholeProtocol"]),
        .library(name: "PortholeTransport", targets: ["PortholeTransport"]),
    ],
    targets: [
        .target(name: "PortholeProtocol"),
        .testTarget(
            name: "PortholeProtocolTests",
            dependencies: ["PortholeProtocol"]
        ),
        .target(name: "PortholeTransport", dependencies: ["PortholeProtocol"]),
        .testTarget(
            name: "PortholeTransportTests",
            dependencies: ["PortholeTransport", "PortholeProtocol"]
        ),
    ]
)

// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "PortviewProtocol",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "PortviewProtocol", targets: ["PortviewProtocol"]),
        .library(name: "PortviewTransport", targets: ["PortviewTransport"]),
        .library(name: "PortviewMedia", targets: ["PortviewMedia"]),
        .library(name: "PortviewHostCore", targets: ["PortviewHostCore"]),
        .library(name: "PortviewClientCore", targets: ["PortviewClientCore"]),
    ],
    targets: [
        .target(name: "PortviewProtocol"),
        .testTarget(
            name: "PortviewProtocolTests",
            dependencies: ["PortviewProtocol"]
        ),
        .target(name: "PortviewTransport", dependencies: ["PortviewProtocol"]),
        .testTarget(
            name: "PortviewTransportTests",
            dependencies: ["PortviewTransport", "PortviewProtocol"]
        ),
        .target(
            name: "PortviewHostCore",
            dependencies: ["PortviewProtocol", "PortviewTransport", "PortviewMedia"]
        ),
        .executableTarget(
            name: "portview-host",
            dependencies: ["PortviewHostCore"]
        ),
        .testTarget(
            name: "PortviewHostTests",
            dependencies: ["PortviewHostCore", "PortviewProtocol"]
        ),
        .target(
            name: "PortviewClientCore",
            dependencies: ["PortviewProtocol", "PortviewTransport"]
        ),
        .testTarget(
            name: "PortviewClientCoreTests",
            dependencies: ["PortviewClientCore", "PortviewProtocol"]
        ),
        .target(name: "PortviewMedia", dependencies: ["PortviewProtocol"]),
        .testTarget(
            name: "PortviewMediaTests",
            dependencies: ["PortviewMedia", "PortviewProtocol", "PortviewTransport"]
        ),
    ]
)

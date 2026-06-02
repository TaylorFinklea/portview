// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PortholeProtocol",
    products: [
        .library(name: "PortholeProtocol", targets: ["PortholeProtocol"]),
    ],
    targets: [
        .target(name: "PortholeProtocol"),
        .testTarget(
            name: "PortholeProtocolTests",
            dependencies: ["PortholeProtocol"]
        ),
    ]
)

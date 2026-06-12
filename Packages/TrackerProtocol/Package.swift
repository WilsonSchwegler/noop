// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackerProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TrackerProtocol", targets: ["TrackerProtocol"])],
    targets: [
        .target(
            name: "TrackerProtocol",
            resources: [.process("Resources/tracker_protocol.json")]
        ),
        .testTarget(
            name: "TrackerProtocolTests",
            dependencies: ["TrackerProtocol"],
            resources: [.process("Resources")]
        ),
    ]
)

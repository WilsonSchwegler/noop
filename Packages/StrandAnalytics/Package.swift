// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandAnalytics",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "StrandAnalytics", targets: ["StrandAnalytics"])],
    dependencies: [
        .package(path: "../TrackerProtocol"),
        .package(path: "../TrackerStore"),
    ],
    targets: [
        .target(name: "StrandAnalytics", dependencies: ["TrackerProtocol", "TrackerStore"]),
        .testTarget(name: "StrandAnalyticsTests", dependencies: ["StrandAnalytics"]),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackerStore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TrackerStore", targets: ["TrackerStore"])],
    dependencies: [
        .package(path: "../TrackerProtocol"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "TrackerStore",
            dependencies: [
                "TrackerProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TrackerStoreTests",
            dependencies: ["TrackerStore"]
        ),
    ]
)

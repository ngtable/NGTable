// swift-tools-version: 6.0

import PackageDescription

// Links NGTable.xcframework and NGTableICU.xcframework the way a customer
// does, as binary targets, and sorts text with the keys from outside:
// build-xcframework.sh copies the frameworks here and runs `swift test`.
let package = Package(
    name: "Consumer",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .binaryTarget(name: "NGTable", path: "NGTable.xcframework"),
        .binaryTarget(name: "NGTableICU", path: "NGTableICU.xcframework"),
        .testTarget(
            name: "ConsumerTests",
            dependencies: ["NGTable", "NGTableICU"]
        ),
    ]
)

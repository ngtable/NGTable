// swift-tools-version: 6.2
// A small app that shows the same live data in NGTable, NSTableView and
// SwiftUI's Table one after another, with the frames a second and how busy
// the main thread is, for the README (Docs/comparison.gif).
import PackageDescription

let package = Package(
    name: "NGTableComparison",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "NGTableComparison",
            dependencies: [.product(name: "NGTable", package: "NGTable")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)

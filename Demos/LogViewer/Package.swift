// swift-tools-version: 6.2
// A log viewer made with NGTable: the Mac's own logs as they come (`log
// stream`), or the last hour of them, with wrapped messages, levels as tags,
// filters by level, process and time, search, grouping and export.
//
//   swift run -c release --package-path Demos/LogViewer
import PackageDescription

let package = Package(
    name: "NGTableLogViewer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "NGTableLogViewer",
            dependencies: [.product(name: "NGTable", package: "NGTable")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)

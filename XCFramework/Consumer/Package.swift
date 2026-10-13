// swift-tools-version: 6.0

import Foundation
import PackageDescription

let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/LocalizationCheck/Info.plist").path

// Links the built NGTable.xcframework the way a customer does, as a binary
// target, and tests it from outside: build-xcframework.sh copies the
// framework here, runs `swift test` and LocalizationCheck.
let package = Package(
    name: "Consumer",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .binaryTarget(name: "NGTable", path: "NGTable.xcframework"),
        // Run with `-AppleLanguages "(ru)"`: checks the table's own strings.
        // Frameworks use the app's language, which is set at launch (a test
        // can't), and only if the app has it: the Info.plist lists Russian.
        .executableTarget(
            name: "LocalizationCheck",
            dependencies: ["NGTable"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", infoPlist,
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
        .testTarget(
            name: "ConsumerTests",
            dependencies: ["NGTable"]
        ),
    ]
)

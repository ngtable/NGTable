// swift-tools-version: 6.0
// Tables compared on the iPad: the same live rows in NGTable, UITableView,
// UICollectionView, SwiftUI's Table and List, with frames a second, the
// main thread's load and a scroll test (open this folder in Xcode, or
// build it with xcodebuild).
import AppleProductTypes
import PackageDescription

let package = Package(
    name: "NGTable iPad Bench",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "NGTable iPad Bench",
            targets: ["AppModule"],
            bundleIdentifier: "com.ngtable.ipad-bench",
            displayVersion: "1.0",
            bundleVersion: "1",
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [.portrait, .landscapeRight, .landscapeLeft, .portraitUpsideDown(.when(deviceFamilies: [.pad]))]
        ),
    ],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [.product(name: "NGTable", package: "NGTable")],
            path: "."
        ),
    ]
)

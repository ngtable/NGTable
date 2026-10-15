// swift-tools-version: 6.0
// The table on the iPad: campaigns with frozen columns, a summary row and
// live values, to try NGTable's UIKit view in the simulator (open this
// folder in Xcode, or build it with xcodebuild).
import AppleProductTypes
import PackageDescription

let package = Package(
    name: "NGTable iPad",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "NGTable iPad",
            targets: ["AppModule"],
            bundleIdentifier: "com.ngtable.ipad-demo",
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

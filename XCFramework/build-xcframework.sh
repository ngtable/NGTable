#!/bin/zsh
# Builds NGTable.xcframework (macOS, arm64 + x86_64, library evolution) from the
# package's sources: XCFramework/build/NGTable.xcframework and a zip of it with
# its SwiftPM checksum, for a `.binaryTarget`. Then tests it from outside, linked
# as a binary target like a customer links it (Consumer/).
#
#   XCFramework/build-xcframework.sh
#
# Needs XcodeGen (`brew install xcodegen`).
set -euo pipefail

here=${0:A:h}
build=$here/build
cd $here

# The framework's version is NGTableView.version.
version=$(sed -n 's/.*nonisolated static let version = "\(.*\)"/\1/p' $here/../Sources/NGTable/NGTableVersion.swift)
[[ $version == <->.<->.<-> ]] || { echo "No version in NGTableVersion.swift" >&2; exit 1 }

rm -rf $build NGTable.xcodeproj
xcodegen generate --quiet --spec project.yml

xcodebuild archive \
    -project NGTable.xcodeproj \
    -scheme NGTable \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath $build/NGTable-macOS.xcarchive \
    -derivedDataPath $build/DerivedData \
    -quiet \
    MARKETING_VERSION=$version

xcodebuild -create-xcframework \
    -archive $build/NGTable-macOS.xcarchive -framework NGTable.framework \
    -output $build/NGTable.xcframework

(cd $build && ditto -c -k --sequesterRsrc --keepParent NGTable.xcframework NGTable.xcframework.zip)
checksum=$(swift package compute-checksum $build/NGTable.xcframework.zip)
echo $checksum > $build/NGTable.xcframework.zip.checksum

# The customer's side: the public API and the framework's own strings.
rm -rf Consumer/NGTable.xcframework Consumer/.build
cp -R $build/NGTable.xcframework Consumer/
swift test --package-path Consumer --quiet
swift build --package-path Consumer --product LocalizationCheck --quiet
$(swift build --package-path Consumer --show-bin-path)/LocalizationCheck -AppleLanguages "(ru)"

echo "$build/NGTable.xcframework"
echo "$build/NGTable.xcframework.zip checksum $checksum"

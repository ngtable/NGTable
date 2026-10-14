#!/bin/zsh
# Builds NGTableICU.xcframework (macOS, arm64 + x86_64, library evolution)
# against the binary NGTable.xcframework, with the ICU linked inside, and a zip
# of it with its SwiftPM checksum, in XCFramework/ICU/build. Then tests both
# frameworks from outside, as binary targets (Consumer/). Its version is
# NGTable's (NGTableView.version).
#
#   XCFramework/ICU/build-xcframework.sh
#
# Needs XcodeGen and NGTable.xcframework, built first by
# XCFramework/build-xcframework.sh (NGTABLE_XCFRAMEWORK: another path).
set -euo pipefail

here=${0:A:h}
build=$here/build
ngtable=${NGTABLE_XCFRAMEWORK:-$here/../build/NGTable.xcframework}
cd $here

version=$(sed -n 's/.*nonisolated static let version = "\(.*\)"/\1/p' $here/../../Sources/NGTable/NGTableVersion.swift)
[[ $version == <->.<->.<-> ]] || { echo "No version in NGTableVersion.swift" >&2; exit 1 }

rm -rf $build NGTableICU.xcodeproj
mkdir -p $build
cp -R $ngtable $build/NGTable.xcframework
xcodegen generate --quiet --spec project.yml

xcodebuild archive \
    -project NGTableICU.xcodeproj \
    -scheme NGTableICU \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath $build/NGTableICU-macOS.xcarchive \
    -derivedDataPath $build/DerivedData \
    -quiet \
    MARKETING_VERSION=$version

xcodebuild -create-xcframework \
    -archive $build/NGTableICU-macOS.xcarchive -framework NGTableICU.framework \
    -output $build/NGTableICU.xcframework

(cd $build && ditto -c -k --sequesterRsrc --keepParent NGTableICU.xcframework NGTableICU.xcframework.zip)
checksum=$(swift package compute-checksum $build/NGTableICU.xcframework.zip)
echo $checksum > $build/NGTableICU.xcframework.zip.checksum

# The customer's side: both frameworks as binary targets, text sorted by the keys.
rm -rf Consumer/NGTable.xcframework Consumer/NGTableICU.xcframework Consumer/.build
cp -R $build/NGTable.xcframework $build/NGTableICU.xcframework Consumer/
swift test --package-path Consumer --quiet

echo "$build/NGTableICU.xcframework"
echo "$build/NGTableICU.xcframework.zip checksum $checksum"

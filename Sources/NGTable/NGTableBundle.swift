#if os(macOS) && !SWIFT_PACKAGE
import Foundation

/// A class of the framework, to find its bundle.
private final class NGTableBundleToken {}

extension Bundle {
    /// NGTable's resources (localized strings) when it's built as a framework
    /// (the XCFramework, `XCFramework/build-xcframework.sh`) instead of a package.
    /// SwiftPM generates `Bundle.module` itself and puts the resources in a bundle
    /// of their own; a framework carries them in its own bundle.
    static let module = Bundle(for: NGTableBundleToken.self)
}
#endif

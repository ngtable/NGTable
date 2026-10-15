import Foundation

// NGTable's version, in one place: the code, bug reports and the binary
// XCFramework (its build scripts read it from here). A commercial license
// covers a major version, so the version also has to be findable in an app
// that links NGTable: Swift keeps strings of up to 15 bytes inside the code,
// where `strings` can't see them, so `binaryMarker` is longer, and the Metal
// renderer names its command queue with it, which keeps it in the app even
// when the linker strips what isn't used.

/// NGTable's version and its marker in a binary, on every platform.
enum NGTableRelease {
    nonisolated static let version = "1.1.0"
    /// NGTable and its version as a string an app's binary keeps (the name of
    /// the Metal renderer's command queue, seen in a GPU frame capture).
    nonisolated static let binaryMarker = "NGTable 1.1.0 Metal renderer"
}

#if os(macOS)
extension NGTableView {
    /// NGTable's version, e.g. "1.0.0" (semantic versioning: a new major
    /// version for changes that break the API).
    public nonisolated static var version: String { NGTableRelease.version }

    nonisolated static var binaryMarker: String { NGTableRelease.binaryMarker }
}
#endif

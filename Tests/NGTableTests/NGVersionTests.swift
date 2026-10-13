#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// NGTable's version is one string, and the binary that links NGTable keeps
/// it findable (a license covers a major version).
@Suite("Version")
@MainActor
struct NGVersionTests {
    @Test func isSemantic() {
        let parts = NGTableView.version.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }, "\(NGTableView.version)")
    }

    @Test func theMarkerNamesTheVersion() {
        #expect(NGTableView.binaryMarker == "NGTable \(NGTableView.version) Metal renderer")
        // Longer than Swift keeps inside the code.
        #expect(NGTableView.binaryMarker.utf8.count > 15)
    }

    @Test func theRendererUsesTheMarker() throws {
        let renderer = try #require(NGMetalRenderer.shared)
        #expect(renderer.queue.label == NGTableView.binaryMarker)
    }

    /// The marker is in the binary as it is (what `strings` finds).
    @Test func theBinaryHoldsTheMarker() throws {
        let path = try #require(Bundle(for: NGTableView.self).executablePath)
        let binary = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        #expect(binary.range(of: Data(NGTableView.binaryMarker.utf8)) != nil, "\(path)")
    }
}
#endif

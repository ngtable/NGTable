#if os(macOS)
import AppKit
import Metal
import Testing
@testable import NGTable

@Suite("Media cache", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct NGMediaCacheTests {
    /// Pictures are decoded at the thumbnail's pixel size, cropped to fill it.
    @Test func picturesFillTheirSize() throws {
        let url = try NGFrameSnapshotTests.testPicture(named: "cache-wide", width: 900, height: 300, hue: 0.3)
        let image = try #require(NGMediaCache.picture(at: url, width: 208, height: 136))
        #expect(image.width == 208 && image.height == 136)
        #expect(NGMediaCache.picture(at: URL(fileURLWithPath: "/nonexistent.png"), width: 10, height: 10) == nil)
    }

    private func waitUntilLoaded(_ cache: NGMediaCache, _ media: NGMedia, size: Int = 100, device: MTLDevice) async throws -> NGMediaCache.State {
        for _ in 0..<200 {
            let state = cache.still(for: media, width: size, height: size, device: device)
            if case .loading = state {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                return state
            }
        }
        Issue.record("Didn't load")
        return .failed
    }

    /// Over the memory limit, the least recently used pictures go first; a
    /// missing file fails instead of loading forever.
    @Test func leastRecentlyUsedPicturesGoFirst() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NGMediaCacheTests-\(UUID())")
        let cache = NGMediaCache(folder: folder)
        cache.memoryLimit = 100 * 100 * 4 * 2   // Two 100×100 pictures.
        let media = try (0..<3).map { NGMedia(image: try NGFrameSnapshotTests.testPicture(named: "cache-\($0)", width: 50, height: 50, hue: Double($0) / 3)) }
        for item in media.prefix(2) {
            guard case .ready = try await waitUntilLoaded(cache, item, device: device) else { Issue.record("not ready"); return }
        }
        // The first is used again, so the second is the least recently used.
        guard case .ready = cache.still(for: media[0], width: 100, height: 100, device: device) else { Issue.record("evicted"); return }
        _ = try await waitUntilLoaded(cache, media[2], device: device)
        #expect({ if case .ready = cache.still(for: media[0], width: 100, height: 100, device: device) { true } else { false } }())
        #expect({ if case .loading = cache.still(for: media[1], width: 100, height: 100, device: device) { true } else { false } }())

        let missing = NGMedia(image: folder.appendingPathComponent("missing.png"))
        guard case .failed = try await waitUntilLoaded(cache, missing, device: device) else { Issue.record("should fail"); return }
        #expect(cache.cachedFile(for: media[0].image!) == media[0].image)
    }

    /// A few load at a time, the latest asked for first; one not asked for
    /// again for a while (scrolled past) isn't loaded.
    @Test func theLatestPicturesLoadFirst() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NGMediaCacheTests-\(UUID())")
        let cache = NGMediaCache(folder: folder)
        cache.concurrentLoads = 0   // Nothing starts yet.
        cache.staleAfter = .milliseconds(50)
        let media = try (0..<4).map { NGMedia(image: try NGFrameSnapshotTests.testPicture(named: "queue-\($0)", width: 40, height: 40, hue: Double($0) / 4)) }
        for item in media { _ = cache.still(for: item, width: 60, height: 60, device: device) }
        try await Task.sleep(for: .milliseconds(120))
        // Only the last is asked for again (the others scrolled past), then loading starts.
        _ = cache.still(for: media[3], width: 60, height: 60, device: device)
        cache.concurrentLoads = 1
        // The latest loads first: the one asked for again, at the size asked.
        guard case .ready = try await waitUntilLoaded(cache, media[3], size: 60, device: device) else { Issue.record("not ready"); return }
        try await Task.sleep(for: .milliseconds(100))   // Past `staleAfter` again.
        // The middle ones were forgotten, not loaded: asking starts them again.
        #expect({ if case .loading = cache.still(for: media[1], width: 60, height: 60, device: device) { true } else { false } }())
    }

    /// Over the disk limit, the files used longest ago are deleted; a deleted
    /// file is no longer offered.
    @Test func theDiskLimitDeletesOldFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NGMediaCacheTests-\(UUID())")
        let cache = NGMediaCache(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<4 {
            let file = folder.appendingPathComponent("file\(index).data")
            try Foundation.Data(repeating: UInt8(index), count: 64 << 10).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)],
                                                  ofItemAtPath: file.path)
        }
        cache.diskLimit = 150 << 10
        for _ in 0..<100 {
            let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            if left.count <= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left.count <= 2)
        #expect(left.contains("file3.data"))   // The newest stays.
    }

    /// A downloaded file deleted since (by the system, or the disk limit)
    /// isn't handed out.
    @Test func deletedFilesArentHandedOut() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NGMediaCacheTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(URL(string: "https://example.com/gone.jpg"))
        let file = folder.appendingPathComponent(NGMediaCache.digest(of: url) + ".jpg")
        try Foundation.Data([1, 2, 3]).write(to: file)
        let cache = NGMediaCache(folder: folder)
        #expect(cache.cachedFile(for: url) == file)
        try FileManager.default.removeItem(at: file)
        #expect(cache.cachedFile(for: url) == nil)
    }

    /// A file handed out (to Quick Look, say) stays when the disk limit
    /// deletes files, even if it was used longest ago.
    @Test func filesHandedOutStay() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NGMediaCacheTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(URL(string: "https://example.com/teaser.jpg"))
        let handedOut = NGMediaCache.digest(of: url) + ".jpg"
        for (index, name) in [handedOut, "a.data", "b.data", "c.data"].enumerated() {
            let file = folder.appendingPathComponent(name)
            try Foundation.Data(repeating: UInt8(index), count: 64 << 10).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)],
                                                  ofItemAtPath: file.path)
        }
        let cache = NGMediaCache(folder: folder)
        #expect(cache.cachedFile(for: url)?.lastPathComponent == handedOut)
        cache.diskLimit = 150 << 10
        for _ in 0..<100 {
            if try FileManager.default.contentsOfDirectory(atPath: folder.path).count <= 2 { break }
            try await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left.contains(handedOut))
        #expect(left.count <= 2)
        #expect(cache.cachedFile(for: url) != nil)
    }

    /// Another size of a picture shown (a window moved to a screen of
    /// another scale) shows the size ready while it loads, not a placeholder.
    @Test func anotherSizeShowsTheReadyOneWhileItLoads() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NGMediaCacheTests-\(UUID())")
        let cache = NGMediaCache(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = try NGFrameSnapshotTests.testPicture(named: "cache-scale", width: 80, height: 80, hue: 0.3)
        let media = NGMedia(image: picture)
        guard case .ready = try await waitUntilLoaded(cache, media, device: device) else { Issue.record("not loaded"); return }
        guard case .ready = cache.still(for: media, width: 50, height: 50, device: device) else {
            Issue.record("a placeholder while the other size loads")
            return
        }
    }

    /// A picture that failed (the file wasn't there, the server was down) is
    /// loaded again after a while, and then shows.
    @Test func failedPicturesAreTriedAgain() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NGMediaCacheTests-\(UUID())")
        let cache = NGMediaCache(folder: folder)
        let file = folder.appendingPathComponent("later.png")
        let media = NGMedia(image: file)
        cache.retryInterval = .seconds(3600)
        guard case .failed = try await waitUntilLoaded(cache, media, device: device) else { Issue.record("should fail"); return }
        // The file appears; within the interval the failure stays.
        let picture = try NGFrameSnapshotTests.testPicture(named: "cache-later", width: 40, height: 40, hue: 0.6)
        try FileManager.default.copyItem(at: picture, to: file)
        #expect({ if case .failed = cache.still(for: media, width: 100, height: 100, device: device) { true } else { false } }())
        cache.retryInterval = .zero
        guard case .ready(let still) = try await waitUntilLoaded(cache, media, device: device) else { Issue.record("should load"); return }
        // Only the texture is kept; the image is read back from it.
        #expect(still.cost == 100 * 100 * 4)
        let image = try #require(still.image)
        #expect(image.width == 100 && image.height == 100)
    }

    /// Textures hold the pixels of the decoded picture exactly.
    @Test func texturesHoldThePicturesPixels() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try NGFrameSnapshotTests.testPicture(named: "cache-pixels", width: 64, height: 48, hue: 0.1)
        let image = try #require(NGMediaCache.picture(at: url, width: 32, height: 24))
        let texture = try #require(NGMediaCache.texture(of: image, device: device))
        let read = try #require(NGMediaCache.Still(texture: texture).image)
        let context = try #require(NGCellDrawing.makeBitmapContext(width: 32, height: 24, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 24))
        let expected = Data(bytes: context.data!, count: context.bytesPerRow * 24)
        let readContext = try #require(NGCellDrawing.makeBitmapContext(width: 32, height: 24, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        readContext.draw(read, in: CGRect(x: 0, y: 0, width: 32, height: 24))
        #expect(Data(bytes: readContext.data!, count: readContext.bytesPerRow * 24) == expected)
    }
}
#endif

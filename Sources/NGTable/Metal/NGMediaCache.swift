#if os(macOS)
import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import Metal
import UniformTypeIdentifiers

// Pictures of media cells (`NGCellValue.media`): files downloaded once into
// the user's Caches folder (kept under `diskLimit`, least recently used out
// first), stills decoded and cropped to the thumbnail's pixel size off the
// main thread, kept as textures (and images) in memory while they fit, least
// recently used out first. A few load at a time, the latest asked for first:
// after a flick through the rows, the ones in view load next, and those
// scrolled past don't load at all.

/// The files and pictures of media cells, shared by every table of the app.
@MainActor
public final class NGMediaCache {
    public static let shared = NGMediaCache()

    /// Bytes of decoded pictures kept in memory (the files stay on disk).
    public var memoryLimit = 128 << 20 {
        didSet { evict() }
    }

    /// Bytes of downloaded files kept in the Caches folder: beyond, the
    /// files used longest ago are deleted (downloaded again when needed).
    public var diskLimit = 1 << 30 {
        didSet { trimDisk() }
    }

    /// Posted on the main thread when a picture finished loading (or failed).
    static let didChangeNotification = Notification.Name("NGMediaCacheDidChange")

    private let folder: URL?
    private var downloads: [URL: Task<URL?, Never>] = [:]

    init(folder: URL? = NGMediaCache.defaultFolder) {
        self.folder = folder
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    nonisolated static var defaultFolder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appending(path: "NGTable/Media", directoryHint: .isDirectory)
    }

    // MARK: Files

    /// The downloaded file of a media URL, if it is on disk already (a file
    /// URL is its own file). Its extension is the content's real type, so
    /// Quick Look and AVFoundation open it.
    public func cachedFile(for url: URL) -> URL? {
        if url.isFileURL { return url }
        let digest = Self.digest(of: url)
        guard let folder, let name = fileNames[digest] else { return nil }
        let file = folder.appending(path: name)
        // The system (or the disk limit) may have deleted it since.
        guard FileManager.default.fileExists(atPath: file.path) else {
            fileNames[digest] = nil
            return nil
        }
        // In use (Quick Look shows it, say): the disk limit leaves it a while.
        recentlyUsed[name] = .now
        return file
    }

    /// Files (by name) handed out or downloaded lately, which the disk limit
    /// leaves for `recentFileTime` whatever their dates say.
    private var recentlyUsed: [String: ContinuousClock.Instant] = [:]
    var recentFileTime: Duration = .seconds(300)

    /// The downloaded files' names by their URL's digest: the folder is
    /// listed once, not on every lookup.
    private lazy var fileNames: [String: String] = {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var index: [String: String] = [:]
        for name in names {
            index[String(name.prefix(while: { $0 != "." }))] = name
        }
        return index
    }()

    nonisolated static func digest(of url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The file of a media URL, downloaded the first time; concurrent callers
    /// wait for the same download. `nil` if it can't be downloaded.
    public func file(for url: URL) async -> URL? {
        // (A download the system deleted since is downloaded again.)
        if let cached = cachedFile(for: url) { return cached }
        if let download = downloads[url] { return await download.value }
        guard let base = baseFile(for: url) else { return nil }
        let task = Task<URL?, Never> {
            guard let (temporary, response) = try? await URLSession.shared.download(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            let file = base.appendingPathExtension(Self.fileExtension(of: temporary, url: url, response: response))
            try? FileManager.default.removeItem(at: file)
            do {
                try FileManager.default.moveItem(at: temporary, to: file)
                return file
            } catch {
                return nil
            }
        }
        downloads[url] = task
        let file = await task.value
        downloads[url] = nil
        if let file {
            fileNames[Self.digest(of: url)] = file.lastPathComponent
            recentlyUsed[file.lastPathComponent] = .now
            downloadsSinceTrim += 1
            if downloadsSinceTrim >= 64 { trimDisk() }
        }
        return file
    }

    // (The first download of a run trims what earlier runs left.)
    private var downloadsSinceTrim = 63
    private var isTrimming = false

    /// Deletes the files used longest ago until the folder is under
    /// `diskLimit` (off the main thread).
    func trimDisk() {
        guard let folder, !isTrimming else { return }
        isTrimming = true
        downloadsSinceTrim = 0
        let limit = diskLimit
        let now = ContinuousClock.now
        recentlyUsed = recentlyUsed.filter { now - $0.value < recentFileTime }
        let keeping = Set(recentlyUsed.keys)
        let started = Date()
        Task {
            let deleted = await Task.detached(priority: .utility) { Self.trim(folder, to: limit, keeping: keeping, since: started) }.value
            for name in deleted { fileNames[String(name.prefix(while: { $0 != "." }))] = nil }
            isTrimming = false
        }
    }

    /// The names of the files deleted: not those in `keeping`, nor files
    /// written since `since` (downloaded again while the folder was read).
    private nonisolated static func trim(_ folder: URL, to limit: Int, keeping: Set<String>, since: Date) -> [String] {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var entries = files.compactMap { file -> (file: URL, size: Int, used: Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.totalFileAllocatedSize ?? 0, values.contentAccessDate ?? values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return [] }
        entries.sort { $0.used < $1.used }
        var deleted: [String] = []
        for entry in entries where total > limit && !keeping.contains(entry.file.lastPathComponent) {
            let written = (try? FileManager.default.attributesOfItem(atPath: entry.file.path)[.modificationDate]) as? Date
            if let written, written >= since { continue }
            guard (try? FileManager.default.removeItem(at: entry.file)) != nil else { continue }
            total -= entry.size
            deleted.append(entry.file.lastPathComponent)
        }
        return deleted
    }

    private func baseFile(for url: URL) -> URL? {
        guard let folder else { return nil }
        return folder.appending(path: Self.digest(of: url))
    }

    /// Pictures get their real type's extension (servers name JPEGs `.png`);
    /// other files the response's or the URL's.
    private nonisolated static func fileExtension(of file: URL, url: URL, response: URLResponse) -> String {
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source),
           let ext = UTType(type as String)?.preferredFilenameExtension {
            return ext
        }
        if let mime = response.mimeType, let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            return ext
        }
        return url.pathExtension.isEmpty ? "data" : url.pathExtension
    }

    // MARK: Stills

    /// A picture ready to draw: a texture of the thumbnail's pixels (the
    /// picture cropped to its proportions). Only the texture is kept (its
    /// pixels are the memory `memoryLimit` counts); `image` reads them back.
    final class Still {
        let texture: MTLTexture
        var cost: Int { texture.width * texture.height * 4 }

        init(texture: MTLTexture) {
            self.texture = texture
        }

        /// The pixels as an image, read from the texture (e.g. for Quick Look).
        var image: CGImage? {
            let width = texture.width, height = texture.height
            guard let context = NGCellDrawing.makeBitmapContext(width: width, height: height,
                                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                  let data = context.data else { return nil }
            texture.getBytes(data, bytesPerRow: context.bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return context.makeImage()
        }
    }

    enum State {
        case loading
        case ready(Still)
        case failed
    }

    private struct Key: Hashable {
        let image: URL?
        let motion: NGMedia.Motion?
        let width: Int
        let height: Int
    }

    private var states: [Key: State] = [:]
    /// A ready still of each media value (its last), shown while another
    /// size of it loads: a window moved to a screen of another scale
    /// doesn't show placeholders meanwhile.
    private var readyStill: [MediaKey: Key] = [:]
    private struct MediaKey: Hashable {
        let image: URL?
        let motion: NGMedia.Motion?
        init(_ key: Key) { (image, motion) = (key.image, key.motion) }
    }
    /// Pictures waiting to load (the latest asked for last), when each was
    /// last asked for (a frame that shows it asks), and how many load now.
    private var pending: [(key: Key, device: MTLDevice)] = []
    private var lastAsked: [Key: ContinuousClock.Instant] = [:]
    private var loadingCount = 0
    /// Pictures loading at once.
    var concurrentLoads = 6 {
        didSet { loadNext() }
    }
    /// A picture not asked for this long (scrolled out of view) isn't loaded.
    var staleAfter: Duration = .seconds(1)
    /// Ready stills, least recently used first.
    private var recent: [Key] = []
    private var cost = 0
    /// When pictures failed to load: they are tried again after `retryInterval`
    /// (a server or the network may have been down for a moment).
    private var failures: [Key: ContinuousClock.Instant] = [:]
    /// How long a picture that failed shows as failed before it is loaded again.
    var retryInterval: Duration = .seconds(30)

    /// The still picture of a media value at a size in pixels; starts loading
    /// it the first time (tables are told with `didChangeNotification`).
    func still(for media: NGMedia, width: Int, height: Int, device: MTLDevice) -> State {
        let key = Key(image: media.image, motion: media.motion, width: width, height: height)
        if let state = states[key] {
            switch state {
            case .ready:
                if let index = recent.lastIndex(of: key), index != recent.count - 1 {
                    recent.remove(at: index)
                    recent.append(key)
                }
                return state
            case .failed:
                guard let failed = failures[key], ContinuousClock.now - failed >= retryInterval else { return state }
                failures[key] = nil
            case .loading:
                lastAsked[key] = .now
                return standIn(for: key) ?? state
            }
        }
        guard media.image != nil || media.motion != nil, width > 0, height > 0 else { return .failed }
        states[key] = .loading
        lastAsked[key] = .now
        pending.append((key, device))
        loadNext()
        return standIn(for: key) ?? .loading
    }

    /// Another size of the same picture, ready, while this one loads.
    private func standIn(for key: Key) -> State? {
        guard let other = readyStill[MediaKey(key)], other != key, case .ready(let still)? = states[other] else { return nil }
        return .ready(still)
    }

    /// Starts loading the latest pictures asked for, up to `concurrentLoads`;
    /// those not asked for lately are forgotten (asked for again if they show).
    private func loadNext() {
        let now = ContinuousClock.now
        var forgot = false
        // Tables draw again, and those that still show a forgotten picture ask for it.
        defer { if forgot { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) } }
        while loadingCount < concurrentLoads, let (key, device) = pending.popLast() {
            guard let asked = lastAsked[key], now - asked < staleAfter, case .loading = states[key] else {
                if case .loading? = states[key] {
                    states[key] = nil
                    forgot = true
                }
                lastAsked[key] = nil
                continue
            }
            loadingCount += 1
            Task {
                let still = await loadStill(key, device: device)
                loadingCount -= 1
                lastAsked[key] = nil
                defer { loadNext() }
                // Forgotten meanwhile (`removeAll()`): nothing to keep.
                guard case .loading = states[key] else { return }
                if let still {
                    states[key] = .ready(still)
                    readyStill[MediaKey(key)] = key
                    recent.append(key)
                    cost += still.cost
                    evict()
                } else {
                    states[key] = .failed
                    failures[key] = .now
                    forgetOldFailures()
                }
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
    }

    /// Failures past their retry time are forgotten when there are many
    /// (they load again if asked for), so they don't pile up.
    private func forgetOldFailures() {
        guard failures.count > 1_024 else { return }
        let now = ContinuousClock.now
        for (key, failed) in failures where now - failed >= retryInterval {
            failures[key] = nil
            states[key] = nil
        }
    }

    /// The candidates in order: a video's frame, then the picture; a GIF's
    /// picture, then its first frame.
    private func loadStill(_ key: Key, device: MTLDevice) async -> Still? {
        var candidates: [(url: URL, isVideo: Bool)] = []
        if case .video(let video) = key.motion { candidates.append((video, true)) }
        if let image = key.image { candidates.append((image, false)) }
        if case .animatedImage(let gif) = key.motion, key.image == nil { candidates.append((gif, false)) }
        for candidate in candidates {
            guard let file = await file(for: candidate.url) else { continue }
            let size = (key.width, key.height)
            let made: NGUncheckedSendable<Still>? = await Task.detached(priority: .userInitiated) {
                let image = candidate.isVideo ? await Self.posterFrame(of: file, width: size.0, height: size.1)
                    : Self.picture(at: file, width: size.0, height: size.1)
                guard let image, let texture = Self.texture(of: image, device: device) else { return nil }
                return NGUncheckedSendable(Still(texture: texture))
            }.value
            if let made { return made.value }
        }
        return nil
    }

    private func evict() {
        while cost > memoryLimit, !recent.isEmpty {
            let key = recent.removeFirst()
            if case .ready(let still) = states[key] { cost -= still.cost }
            states[key] = nil
            if readyStill[MediaKey(key)] == key { readyStill[MediaKey(key)] = nil }
        }
    }

    /// Forgets the pictures in memory and deletes the downloaded files.
    public func removeAll() {
        states.removeAll()
        readyStill.removeAll()
        failures.removeAll()
        pending.removeAll()
        lastAsked.removeAll()
        NGMediaPlayer.recentGIFs.removeAll()
        recent.removeAll()
        cost = 0
        fileNames.removeAll()
        if let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
        }
    }

    // MARK: Decoding (worker threads)

    /// A picture's first frame, downsampled while decoding and cropped to fill
    /// `width` × `height` pixels.
    nonisolated static func picture(at file: URL, width: Int, height: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int, let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        // Decoded just large enough to fill the thumbnail (an approximation
        // for rotated pictures, which are rare among creatives).
        guard let decoded = decoded(source, at: 0, toFill: width, height, properties: properties) else { return nil }
        return filled(decoded, width: width, height: height)
    }

    /// Frame `index` of an image source, downsampled while decoding to just
    /// cover `width` × `height` pixels (`nil` if it can't be decoded).
    nonisolated static func decoded(_ source: CGImageSource, at index: Int, toFill width: Int, _ height: Int,
                                    properties: [CFString: Any]?) -> CGImage? {
        guard let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int, pixelWidth > 0, pixelHeight > 0 else {
            return CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        let scale = min(1, max(Double(width) / Double(pixelWidth), Double(height) / Double(pixelHeight)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((Double(max(pixelWidth, pixelHeight)) * scale).rounded(.up)) + 1,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// A frame from a video's first second (its first frame if it is shorter).
    nonisolated static func posterFrame(of file: URL, width: Int, height: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width * 2, height: height * 2)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        for seconds in [1.0, 0] {
            if let (frame, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                return filled(frame, width: width, height: height)
            }
        }
        return nil
    }

    /// The image scaled to cover `width` × `height` pixels, centered and
    /// cropped, in sRGB like everything the renderer draws.
    nonisolated static func filled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = NGCellDrawing.makeBitmapContext(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            return nil
        }
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        return context.makeImage()
    }

    /// A texture of an image's premultiplied BGRA pixels (made by `filled`).
    nonisolated static func texture(of image: CGImage, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: NGMetalRenderer.pixelFormat, width: image.width,
                                                                  height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // Images made by `filled` already have the texture's pixel format:
        // their bytes are copied as they are, without drawing them again.
        if image.bitmapInfo.rawValue == NGCellDrawing.bitmapInfo, image.bitsPerPixel == 32,
           image.colorSpace?.name == CGColorSpace.sRGB, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * image.height {
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: bytes,
                            bytesPerRow: image.bytesPerRow)
            return texture
        }
        guard let context = NGCellDrawing.makeBitmapContext(width: image.width, height: image.height,
                                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: data,
                        bytesPerRow: context.bytesPerRow)
        return texture
    }
}
#endif

#if os(macOS)
import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import Metal

// The motion of the media cell under the pointer (`NGMedia.motion`): a video
// decoded by AVFoundation into Metal textures, or a GIF's frames decoded at
// the thumbnail's size, played muted and looping. A display link runs only
// while something plays; each new frame asks the table for a Metal frame,
// which draws the current texture in place of the still picture.

@MainActor
final class NGMediaPlayer {
    /// The cell object playing, and the value it showed when it started:
    /// a recycled cell (or a changed value) doesn't show the motion. A new
    /// cell showing the same value under the pointer (its row was reloaded)
    /// takes over (`NGTableView.syncMediaPlayerWithHoveredCell()`).
    var cell: NGDrawnCell
    let media: NGMedia
    /// The frame to draw, `nil` until the first one is decoded.
    private(set) var texture: MTLTexture?
    /// What `texture` belongs to (a video frame's Core Video texture): a frame
    /// that draws `texture` keeps it until the GPU is done (see
    /// `NGMetalRenderer.draw(keepingAlive:)`), or the decoder could reuse its
    /// pixel buffer while the GPU still reads it.
    private(set) var textureOwner: AnyObject?
    private let onFrame: () -> Void

    private var link: CADisplayLink?
    private var task: Task<Void, Never>?
    // Video.
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var textureCache: CVMetalTextureCache?
    private var endObserver: NSObjectProtocol?
    // GIF.
    private var frames: [(texture: MTLTexture, delay: Double)] = []
    private var animationStart: CFTimeInterval = 0
    private var frameIndex = -1

    init(cell: NGDrawnCell, media: NGMedia, onFrame: @escaping () -> Void) {
        self.cell = cell
        self.media = media
        self.onFrame = onFrame
    }

    /// Starts once the file is downloaded (the still shows meanwhile).
    func start(in view: NSView, device: MTLDevice, pixelSize: (width: Int, height: Int)) {
        guard let motion = media.motion else { return }
        // The view weakly too: a download outlives a closed window.
        task = Task { [weak self, weak view] in
            switch motion {
            case .video(let url):
                guard let file = await NGMediaCache.shared.file(for: url), !Task.isCancelled, let view else { return }
                self?.playVideo(file, device: device, in: view)
            case .animatedImage(let url):
                let key = GIFKey(url: url, width: pixelSize.width, height: pixelSize.height)
                if let decoded = Self.recentGIFs.frames(for: key) {
                    if let view { self?.animate(decoded, in: view) }
                    return
                }
                guard let file = await NGMediaCache.shared.file(for: url), !Task.isCancelled else { return }
                // A detached task isn't cancelled with this one: the pointer
                // leaving the cell stops the decoding too.
                let decoding = Task.detached(priority: .userInitiated) {
                    NGUncheckedSendable(Self.gifFrames(of: file, width: pixelSize.width, height: pixelSize.height, device: device))
                }
                let decoded = await withTaskCancellationHandler {
                    await decoding.value.value
                } onCancel: {
                    decoding.cancel()
                }
                guard !Task.isCancelled, !decoded.isEmpty else { return }
                Self.recentGIFs.insert(decoded, for: key)
                if let view { self?.animate(decoded, in: view) }
            }
        }
    }

    func stop() {
        task?.cancel()
        link?.invalidate()
        link = nil
        player?.pause()
        player = nil
        output = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        frames = []
        texture = nil
        textureOwner = nil
    }

    // MARK: Video

    private func playVideo(_ file: URL, device: MTLDevice, in view: NSView) {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return }
        let item = AVPlayerItem(url: file)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { [weak player] _ in
            MainActor.assumeIsolated {
                player?.seek(to: .zero)
                player?.play()
            }
        }
        textureCache = cache
        self.output = output
        self.player = player
        player.play()
        startLink(in: view)
    }

    private func nextVideoFrame() {
        guard let output, let textureCache else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        var frame: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, NGMetalRenderer.pixelFormat,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &frame)
        guard let frame, let texture = CVMetalTextureGetTexture(frame) else { return }
        textureOwner = frame
        self.texture = texture
        onFrame()
    }

    // MARK: GIF

    private func animate(_ frames: [(texture: MTLTexture, delay: Double)], in view: NSView) {
        self.frames = frames
        animationStart = CACurrentMediaTime()
        startLink(in: view)
    }

    private func nextGIFFrame() {
        let total = frames.reduce(0) { $0 + $1.delay }
        guard total > 0 else { return }
        var elapsed = (CACurrentMediaTime() - animationStart).truncatingRemainder(dividingBy: total)
        var index = 0
        while index < frames.count - 1, elapsed >= frames[index].delay {
            elapsed -= frames[index].delay
            index += 1
        }
        guard index != frameIndex else { return }
        frameIndex = index
        texture = frames[index].texture
        onFrame()
    }

    /// A GIF's frames (at most 300) filled to the thumbnail's pixels, with
    /// their delays (browsers' minimum of 20 ms; 100 ms when missing).
    /// Frames are decoded just large enough (not at the GIF's full size);
    /// a cancelled task stops between frames and gets none.
    nonisolated static func gifFrames(of file: URL, width: Int, height: Int, device: MTLDevice) -> [(texture: MTLTexture, delay: Double)] {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return [] }
        var frames: [(texture: MTLTexture, delay: Double)] = []
        for index in 0..<min(CGImageSourceGetCount(source), 300) {
            guard !Task.isCancelled else { return [] }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            guard let image = NGMediaCache.decoded(source, at: index, toFill: width, height, properties: properties),
                  let filled = NGMediaCache.filled(image, width: width, height: height),
                  let texture = NGMediaCache.texture(of: filled, device: device) else { continue }
            frames.append((texture, delay < 0.02 ? 0.1 : delay))
        }
        return frames
    }

    // MARK: Recent GIFs

    struct GIFKey: Hashable {
        let url: URL
        let width: Int
        let height: Int
    }

    /// GIFs decoded lately: moving the pointer back to a cell plays it again
    /// without decoding every frame again.
    static let recentGIFs = NGRecentGIFs()

    // MARK: Display link

    private func startLink(in view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: NGMediaPlayerLinkTarget(self), selector: #selector(NGMediaPlayerLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// What the display link does on each frame (tests call it directly:
    /// they have no display).
    func step() {
        if output != nil {
            nextVideoFrame()
        } else {
            nextGIFFrame()
        }
    }
}

/// Decoded GIF frames by file and size, least recently used out first, up to a
/// memory limit.
@MainActor
final class NGRecentGIFs {
    typealias Frames = [(texture: MTLTexture, delay: Double)]
    /// Bytes of frames kept.
    var memoryLimit = 64 << 20 {
        didSet { evict() }
    }
    private var entries: [NGMediaPlayer.GIFKey: Frames] = [:]
    private var order: [NGMediaPlayer.GIFKey] = []
    private(set) var cost = 0

    func frames(for key: NGMediaPlayer.GIFKey) -> Frames? {
        guard let frames = entries[key] else { return nil }
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return frames
    }

    func insert(_ frames: Frames, for key: NGMediaPlayer.GIFKey) {
        guard entries[key] == nil else { return }
        entries[key] = frames
        order.append(key)
        cost += Self.cost(of: frames)
        evict()
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        cost = 0
    }

    private static func cost(of frames: Frames) -> Int {
        frames.reduce(0) { $0 + $1.texture.width * $1.texture.height * 4 }
    }

    private func evict() {
        while cost > memoryLimit, !order.isEmpty {
            let key = order.removeFirst()
            if let frames = entries.removeValue(forKey: key) { cost -= Self.cost(of: frames) }
        }
    }
}

/// Forwards display link frames without retaining the player.
@MainActor
private final class NGMediaPlayerLinkTarget: NSObject {
    weak var player: NGMediaPlayer?

    init(_ player: NGMediaPlayer) {
        self.player = player
    }

    @objc func step(_ link: CADisplayLink) {
        guard let player else {
            link.invalidate()
            return
        }
        player.step()
    }
}
#endif

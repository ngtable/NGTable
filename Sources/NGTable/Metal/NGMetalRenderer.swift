#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Metal
import os

// The table's renderer: everything is a quad drawn in one call. A quad is a solid rectangle (backgrounds) or a glyph from the atlas,
// tinted (text) or as it is (color emoji), clipped to its cell. Coordinates
// are device pixels, top-down, like the views.

/// One quad, as the shaders read it.
struct NGMetalQuad {
    /// x, y, width, height in device pixels.
    var rect: SIMD4<Float>
    /// The atlas rectangle in texture pixels (glyphs); for rounded rectangles
    /// the corner radius in pixels and the rounded corners (`CACornerMask` bits).
    var source: SIMD4<Float>
    /// Premultiplied color: the rectangle's, or the text's.
    var color: SIMD4<Float>
    /// Pixels outside min x, min y, max x, max y are not drawn.
    var clip: SIMD4<Float>
    /// 0: solid, 1: tinted glyph, 2: color glyph, 3: rounded rectangle,
    /// 4: picture (y: corner radius in pixels, z: the frame's texture slot;
    /// `source` is the texture area in 0...1), 5: a line segment with round
    /// ends (`source`: its ends in pixels; y: half its width in 1/256 pixels),
    /// 6: the area under a segment down to the rectangle's bottom (`source`:
    /// the segment's ends in pixels). A segment without its start's round end
    /// (z: 1) continues a polyline: the previous one's end covers the join,
    /// and edges aren't blended twice.
    var kind: SIMD4<UInt32>
}

/// Text a cell laid out, for the next frames (see `NGMetalRenderer.appendText`).
struct NGLaidOutText {
    let text: String
    let font: CTFont
    let width: CGFloat
    let shaped: NGShapedText
}

@MainActor
final class NGMetalRenderer {
    /// While set, the quad ranges of each line of text appended (right to
    /// left, content is mirrored but a line moves whole: see
    /// `NGTableView.appendMirrored`).
    var textRuns: [Range<Int>]?
    let device: MTLDevice
    let queue: MTLCommandQueue
    let atlas: NGGlyphAtlas
    /// Texts drawn (for tests: cached cells don't draw theirs again).
    var textAppends = 0
    let shaper: NGTextShaper
    private let pipeline: MTLRenderPipelineState
    /// Quad buffers the GPU is done with, for the next draws. A draw takes one
    /// (or makes one) and gives it back when its command buffer completes, so
    /// no draw waits for the GPU, however many tables and layers draw.
    private let freeBuffers = OSAllocatedUnfairLock(uncheckedState: [MTLBuffer]())
    /// Spare buffers kept; more are released.
    nonisolated private static let freeBufferLimit = 16

    nonisolated static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// The GPU tables draw on: the integrated one of a Mac with two (a table
    /// is light work; the default device would switch the Mac to the discrete
    /// one and drain its battery), else the default.
    static func preferredDevice() -> MTLDevice? {
        #if os(macOS)
        MTLCopyAllDevices().first { $0.isLowPower && !$0.isRemovable } ?? MTLCreateSystemDefaultDevice()
        #else
        MTLCreateSystemDefaultDevice()
        #endif
    }

    /// The renderer tables share (`nil` without Metal): one set of shaders and
    /// one glyph atlas for the whole app.
    static let shared: NGMetalRenderer? = NGMetalRenderer()

    /// - Parameter atlasSize: The glyph atlas's starting size in pixels (tests make it small to fill it).
    init?(device: MTLDevice? = NGMetalRenderer.preferredDevice(), atlasSize: Int = 2048) {
        guard let device, let queue = device.makeCommandQueue(), let atlas = NGGlyphAtlas(device: device, size: atlasSize) else { return nil }
        queue.label = NGTableRelease.binaryMarker
        // Compiled at run time: SwiftPM doesn't build .metal files.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            assertionFailure("NGMetalRenderer: the shaders don't compile: \(error)")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "quadVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quadFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = Self.pixelFormat
        // Premultiplied "over", in the encoded (not linear) values, like Core Graphics and Core Animation.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.atlas = atlas
        self.shaper = NGTextShaper(atlas: atlas)
        self.pipeline = pipeline
    }

    /// Draws quads into a texture (a drawable's or an offscreen one) of `size` pixels.
    /// - Parameter completion: Called (on any thread) when the GPU is done.
    /// - Parameter presentsWithTransaction: Shows the drawable with the current
    ///   Core Animation transaction (the layer's `presentsWithTransaction`),
    ///   so it changes in the same frame as the views around it.
    /// - Parameter keepingAlive: Objects the textures depend on (Core Video
    ///   textures of video frames), kept until the GPU is done with the draw.
    func draw(_ quads: [NGMetalQuad], textures: [MTLTexture] = [], into texture: MTLTexture, clearColor: MTLClearColor,
              present drawable: MTLDrawable? = nil, presentsWithTransaction: Bool = false, keepingAlive: [AnyObject] = [],
              completion: (@Sendable () -> Void)? = nil, gpuTime: (@Sendable (CFTimeInterval) -> Void)? = nil) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            completion?()
            return
        }
        let buffer = quads.isEmpty ? nil : buffer(for: quads)
        if let buffer {
            var viewport = SIMD2<Float>(Float(texture.width), Float(texture.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentTexture(atlas.texture, index: 1)
            func drawQuads(_ range: Range<Int>) {
                guard !range.isEmpty else { return }
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count,
                                       baseInstance: range.lowerBound)
            }
            // One call for everything between pictures; each picture binds its
            // texture. A picture without one is left out (it would sample the atlas).
            var start = 0
            for index in quads.indices where quads[index].kind.x == 4 {
                drawQuads(start..<index)
                let slot = Int(quads[index].kind.z)
                if slot < textures.count {
                    encoder.setFragmentTexture(textures[slot], index: 1)
                    drawQuads(index..<(index + 1))
                }
                start = index + 1
            }
            drawQuads(start..<quads.count)
        }
        encoder.endEncoding()
        if let drawable, !presentsWithTransaction {
            commands.present(drawable)
        }
        let pool = freeBuffers
        let used = buffer.map(NGUncheckedSendable.init)
        let owners = NGUncheckedSendable(keepingAlive)
        commands.addCompletedHandler { commands in
            // How long the GPU drew the frame.
            if let gpuTime, commands.gpuEndTime > commands.gpuStartTime { gpuTime(commands.gpuEndTime - commands.gpuStartTime) }
            // Released here, not before: the GPU has read the textures.
            withExtendedLifetime(owners) {}
            if let used {
                pool.withLockUnchecked { free in
                    if free.count < Self.freeBufferLimit {
                        free.append(used.value)
                    } else if let smallest = free.indices.min(by: { free[$0].length < free[$1].length }),
                              free[smallest].length < used.value.length {
                        // Full: the larger buffer stays, so large frames find one.
                        free[smallest] = used.value
                    }
                }
            }
            completion?()
        }
        commands.commit()
        if let drawable, presentsWithTransaction {
            commands.waitUntilScheduled()
            drawable.present()
        }
    }

    /// A buffer the GPU isn't reading (a free one large enough, or a new one) with the quads in it.
    private func buffer(for quads: [NGMetalQuad]) -> MTLBuffer? {
        let length = quads.count * MemoryLayout<NGMetalQuad>.stride
        let reused = freeBuffers.withLockUnchecked { free -> MTLBuffer? in
            guard let index = free.firstIndex(where: { $0.length >= length }) else { return nil }
            return free.remove(at: index)
        }
        // New ones get room to grow, so a frame with a few more quads reuses them.
        guard let buffer = reused ?? device.makeBuffer(length: max(length * 3 / 2, 1 << 16), options: .storageModeShared) else {
            return nil
        }
        quads.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: length)
        }
        return buffer
    }

    // MARK: Building quads

    /// The quads `build` makes, built again if the glyph atlas started over
    /// meanwhile: the glyphs placed before that point to bitmaps of the old
    /// texture. If a second attempt fills it too, one frame's glyphs don't
    /// fit: the atlas grows and the frame is built a last time.
    func quadsSurvivingAtlasResets(_ build: () -> [NGMetalQuad]) -> [NGMetalQuad] {
        var quads: [NGMetalQuad] = []
        for attempt in 0..<3 {
            let resets = atlas.resetCount
            quads = build()
            guard atlas.resetCount != resets else { break }
            if attempt == 1, !atlas.grow() { break }
        }
        return quads
    }

    /// Quads for one line of text in a cell (padding, alignment, vertical
    /// centering), clipped to the cell.
    /// - Parameters:
    ///   - cell: The cell in points.
    ///   - scale: Device pixels per point.
    ///   - color: The text color, premultiplied.
    func appendText(_ text: String, font: CTFont, alignment: NSTextAlignment, in cell: CGRect, scale: CGFloat,
                    color: SIMD4<Float>, clip: CGRect? = nil, to quads: inout [NGMetalQuad]) {
        var laidOut: NGLaidOutText?
        appendText(text, font: font, alignment: alignment, in: cell, scale: scale, color: color, clip: clip,
                   laidOut: &laidOut, to: &quads)
    }

    /// The same, reusing the text a cell laid out for an earlier frame
    /// (`laidOut`, kept by the cell) while its text, font and width stay:
    /// a frame of unchanged cells doesn't look their texts up again (hashing
    /// every string of the frame).
    func appendText(_ text: String, font: CTFont, alignment: NSTextAlignment, in cell: CGRect, scale: CGFloat,
                    color: SIMD4<Float>, clip: CGRect? = nil, laidOut: inout NGLaidOutText?, to quads: inout [NGMetalQuad]) {
        textAppends &+= 1
        guard !text.isEmpty else { return }
        let available = max(0, cell.width - 2 * NGMetrics.cellPadding)
        let shaped: NGShapedText
        if let kept = laidOut, kept.font === font, kept.width == available, kept.text == text {
            shaped = kept.shaped
        } else {
            let misses = shaper.missCount
            shaped = shaper.shape(text, font: font, width: available)
            // Text still to be laid out (a frame collecting what's missing) is asked for again.
            laidOut = shaper.missCount == misses ? NGLaidOutText(text: text, font: font, width: available, shaped: shaped) : nil
        }
        let x: CGFloat = switch alignment {
        case .right: NGMetrics.cellPadding + available - shaped.width
        case .center: NGMetrics.cellPadding + ((available - shaped.width) / 2)
        default: NGMetrics.cellPadding
        }
        let top = ((cell.height - NGLineHeights.height(of: font as NGPlatformFont)) / 2).rounded()
        appendGlyphs(shaped, font: font, x: cell.minX + x, baseline: cell.minY + top + CTFontGetAscent(font),
                     clip: clip ?? cell, scale: scale, color: color, to: &quads)
    }

    /// Quads for a line of text in `rect` (no padding), aligned and truncated
    /// to its width, on `baseline` (points).
    func appendLine(_ text: String, font: CTFont, alignment: NSTextAlignment, in rect: CGRect, baseline: CGFloat, scale: CGFloat,
                    color: SIMD4<Float>, clip: CGRect, to quads: inout [NGMetalQuad]) {
        guard !text.isEmpty, rect.width > 0 else { return }
        let shaped = shaper.shape(text, font: font, width: rect.width)
        let x: CGFloat = switch alignment {
        case .right: rect.maxX - shaped.width
        case .center: rect.minX + ((rect.width - shaped.width) / 2)
        default: rect.minX
        }
        appendGlyphs(shaped, font: font, x: x, baseline: baseline, clip: clip, scale: scale, color: color, to: &quads)
    }

    /// Quads for laid-out text with its pen starting at `x` on `baseline` (points).
    func appendGlyphs(_ shaped: NGShapedText, font: CTFont, x: CGFloat, baseline baselinePoints: CGFloat, clip clipRect: CGRect,
                      scale: CGFloat, color: SIMD4<Float>, to quads: inout [NGMetalQuad]) {
        // Each line's glyphs as one run, for mirroring right to left (see `textRuns`).
        let runStart = quads.count
        defer { if textRuns != nil, quads.count > runStart { textRuns!.append(runStart..<quads.count) } }
        // Like Core Graphics, the baseline isn't rounded: glyphs are rasterized at its offset.
        let exactBaseline = baselinePoints * scale
        let baseline = floor(exactBaseline)
        let rise = min(NGGlyphAtlas.rises - 1, Int(((exactBaseline - baseline) * CGFloat(NGGlyphAtlas.rises)).rounded()))
        let clip = Self.pixels(clipRect, scale: scale)
        // Fallback fonts change within a line; the table follows them.
        var table: NGGlyphAtlas.GlyphTable?
        var tableFont = -1
        for glyph in shaped.glyphs {
            if glyph.font != tableFont {
                table = atlas.table(font: glyph.font, rise: rise, scale: scale)
                tableFont = glyph.font
            }
            let pen = (x + glyph.x) * scale
            // Down to a quarter pixel, like Core Graphics (exact at 2×; at 1× some
            // glyphs of text drawn as lines land a quarter pixel apart).
            let whole = floor(pen)
            let phase = min(NGGlyphAtlas.phases - 1, Int(((pen - whole) * CGFloat(NGGlyphAtlas.phases)).rounded(.down)))
            guard let table, let entry = atlas.entry(in: table, glyph: glyph.glyph, phase: phase), entry.width > 0 else { continue }
            let rect = SIMD4<Float>(Float(whole) - Float(entry.originX), Float(baseline) - Float(entry.baselineFromTop),
                                    Float(entry.width), Float(entry.height))
            let source = SIMD4<Float>(Float(entry.x), Float(entry.y), Float(entry.width), Float(entry.height))
            // Color glyphs (emoji) aren't tinted: white, which fades multiply.
            quads.append(NGMetalQuad(rect: rect, source: source, color: entry.isColor ? SIMD4(1, 1, 1, 1) : color, clip: clip,
                                     kind: SIMD4(entry.isColor ? 2 : 1, 0, 0, 0)))
        }
    }

    /// Quads for an icon from the atlas (drawn in white once, tinted), with
    /// its top left corner at `origin` (points, whole pixels).
    func appendIcon(_ entry: NGGlyphAtlas.Entry, at origin: CGPoint, clip: CGRect, scale: CGFloat, color: SIMD4<Float>,
                    to quads: inout [NGMetalQuad]) {
        guard entry.width > 0 else { return }
        let rect = SIMD4<Float>(Float((origin.x * scale).rounded()), Float((origin.y * scale).rounded()), Float(entry.width), Float(entry.height))
        quads.append(NGMetalQuad(rect: rect, source: SIMD4(Float(entry.x), Float(entry.y), Float(entry.width), Float(entry.height)),
                                 color: entry.isColor ? SIMD4(1, 1, 1, 1) : color, clip: Self.pixels(clip, scale: scale),
                                 kind: SIMD4(entry.isColor ? 2 : 1, 0, 0, 0)))
    }

    /// A solid rectangle in points.
    static func rectangle(_ rect: CGRect, scale: CGFloat, color: SIMD4<Float>, clip: CGRect? = nil) -> NGMetalQuad {
        let pixels = SIMD4<Float>(Float(rect.minX * scale), Float(rect.minY * scale), Float(rect.width * scale), Float(rect.height * scale))
        return NGMetalQuad(rect: pixels, source: .zero, color: color, clip: Self.pixels(clip ?? rect, scale: scale), kind: .zero)
    }

    /// A picture filling `rect` (points) with rounded corners, from texture
    /// `slot` of the frame.
    /// - Parameter source: The texture's area to draw, in 0...1.
    static func picture(_ rect: CGRect, slot: Int, radius: CGFloat, scale: CGFloat, opacity: Float = 1,
                        source: SIMD4<Float> = SIMD4(0, 0, 1, 1), clip: CGRect) -> NGMetalQuad {
        let pixels = SIMD4<Float>(Float(rect.minX * scale), Float(rect.minY * scale), Float(rect.width * scale), Float(rect.height * scale))
        return NGMetalQuad(rect: pixels, source: source, color: SIMD4(repeating: opacity), clip: Self.pixels(clip, scale: scale),
                           kind: SIMD4(4, UInt32(max(0, radius * scale).rounded()), UInt32(slot), 0))
    }

    /// A rectangle with rounded corners (`corners` as `CACornerMask` bits; the
    /// top-down coordinates put "min Y" at the top), antialiased.
    static func roundedRectangle(_ rect: CGRect, radius: CGFloat, corners: CACornerMask, scale: CGFloat, color: SIMD4<Float>,
                                 clip: CGRect? = nil) -> NGMetalQuad {
        guard radius > 0, !corners.isEmpty else { return rectangle(rect, scale: scale, color: color, clip: clip) }
        let pixels = SIMD4<Float>(Float(rect.minX * scale), Float(rect.minY * scale), Float(rect.width * scale), Float(rect.height * scale))
        return NGMetalQuad(rect: pixels, source: SIMD4(Float(radius * scale), Float(corners.rawValue), 0, 0), color: color,
                           clip: Self.pixels(clip ?? rect, scale: scale), kind: SIMD4(3, 0, 0, 0))
    }

    /// A line from one point to another (points) of a width, with round ends:
    /// segments of a polyline join round (`continues`: the previous segment
    /// ends where this one starts, and draws the join). Antialiased.
    static func segment(from start: CGPoint, to end: CGPoint, width: CGFloat, continues: Bool = false, scale: CGFloat,
                        color: SIMD4<Float>, clip: CGRect) -> NGMetalQuad {
        let a = SIMD2<Float>(Float(start.x * scale), Float(start.y * scale)), b = SIMD2<Float>(Float(end.x * scale), Float(end.y * scale))
        let half = Float(width * scale / 2)
        // The bounds with the round ends and a pixel for the antialiasing.
        let low = SIMD2(min(a.x, b.x), min(a.y, b.y)) - (half + 1), high = SIMD2(max(a.x, b.x), max(a.y, b.y)) + (half + 1)
        return NGMetalQuad(rect: SIMD4(low.x, low.y, high.x - low.x, high.y - low.y), source: SIMD4(a.x, a.y, b.x, b.y), color: color,
                           clip: Self.pixels(clip, scale: scale), kind: SIMD4(5, UInt32((half * 256).rounded()), continues ? 1 : 0, 0))
    }

    /// The area under a segment (points) down to `baseline`: a polyline's
    /// areas, side by side, fill under it without overlapping.
    static func area(from start: CGPoint, to end: CGPoint, baseline: CGFloat, scale: CGFloat, color: SIMD4<Float>,
                     clip: CGRect) -> NGMetalQuad {
        let a = SIMD2<Float>(Float(start.x * scale), Float(start.y * scale)), b = SIMD2<Float>(Float(end.x * scale), Float(end.y * scale))
        let left = min(a.x, b.x), top = min(a.y, b.y) - 1, bottom = Float(baseline * scale)
        return NGMetalQuad(rect: SIMD4(left, top, abs(b.x - a.x), max(0, bottom - top)), source: SIMD4(a.x, a.y, b.x, b.y), color: color,
                           clip: Self.pixels(clip, scale: scale), kind: SIMD4(6, 0, 0, 0))
    }

    /// A clip rectangle in points as min x, min y, max x, max y in pixels.
    static func pixels(_ rect: CGRect, scale: CGFloat) -> SIMD4<Float> {
        SIMD4(Float(rect.minX * scale), Float(rect.minY * scale), Float(rect.maxX * scale), Float(rect.maxY * scale))
    }

    #if os(macOS)
    /// A color as the shaders take it: premultiplied, in sRGB.
    static func premultiplied(_ color: NSColor) -> SIMD4<Float> {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let alpha = Float(rgb.alphaComponent)
        return SIMD4(Float(rgb.redComponent) * alpha, Float(rgb.greenComponent) * alpha, Float(rgb.blueComponent) * alpha, alpha)
    }
    #endif

    /// The same for a resolved Core Graphics color.
    static func premultiplied(_ color: CGColor) -> SIMD4<Float> {
        guard let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let components = rgb.components, components.count >= 4 else { return .zero }
        let alpha = Float(components[3])
        return SIMD4(Float(components[0]) * alpha, Float(components[1]) * alpha, Float(components[2]) * alpha, alpha)
    }

    // MARK: Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Quad {
        float4 rect;
        float4 source;
        float4 color;
        float4 clip;
        uint4 kind;
    };

    struct Fragment {
        float4 position [[position]];
        float2 source;
        float4 color;
        float4 clip [[flat]];
        float4 rect [[flat]];
        float4 shape [[flat]];
        float radius [[flat]];
        uint kind [[flat]];
        uint variant [[flat]];
    };

    vertex Fragment quadVertex(uint vertexID [[vertex_id]], uint quadID [[instance_id]],
                               constant Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
        Quad quad = quads[quadID];
        float2 corner = float2(vertexID & 1, vertexID >> 1);
        float2 pixel = quad.rect.xy + corner * quad.rect.zw;
        Fragment out;
        out.position = float4(pixel.x / viewport.x * 2.0 - 1.0, 1.0 - pixel.y / viewport.y * 2.0, 0.0, 1.0);
        out.source = quad.source.xy + corner * quad.source.zw;
        out.color = quad.color;
        out.clip = quad.clip;
        out.rect = quad.rect;
        out.shape = quad.source;
        out.radius = float(quad.kind.y);
        out.kind = quad.kind.x;
        out.variant = quad.kind.z;
        return out;
    }

    fragment float4 quadFragment(Fragment in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                 texture2d<float> picture [[texture(1)]]) {
        float2 pixel = in.position.xy;
        if (pixel.x < in.clip.x || pixel.y < in.clip.y || pixel.x >= in.clip.z || pixel.y >= in.clip.w) {
            discard_fragment();
        }
        if (in.kind == 0) {
            return in.color;
        }
        if (in.kind == 3) {
            // Rounded rectangle: the signed distance to its edge, rounded only
            // at the corners in the mask (1: min x min y, 2: max x min y,
            // 4: min x max y, 8: max x max y), antialiased over a pixel.
            float2 halfSize = in.rect.zw * 0.5;
            float2 p = pixel - (in.rect.xy + halfSize);
            uint mask = uint(in.shape.y);
            uint corner = p.x < 0 ? (p.y < 0 ? 1u : 4u) : (p.y < 0 ? 2u : 8u);
            float r = (mask & corner) != 0 ? min(in.shape.x, min(halfSize.x, halfSize.y)) : 0.0;
            float2 q = abs(p) - halfSize + r;
            float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
            return in.color * clamp(0.5 - d, 0.0, 1.0);
        }
        if (in.kind == 5) {
            // A segment with round ends: the distance to it, antialiased over a pixel.
            float2 a = in.shape.xy, b = in.shape.zw;
            float2 pa = pixel - a, ba = b - a;
            float along = dot(pa, ba) / max(dot(ba, ba), 1e-6);
            // Continuing a polyline: the start's round end is the previous segment's.
            if (in.variant == 1 && along < 0.0) {
                discard_fragment();
            }
            float h = clamp(along, 0.0, 1.0);
            float d = length(pa - ba * h) - in.radius / 256.0;
            return in.color * clamp(0.5 - d, 0.0, 1.0);
        }
        if (in.kind == 6) {
            // Under a segment: covered below the line, antialiased across it.
            float2 a = in.shape.xy, b = in.shape.zw;
            float t = abs(b.x - a.x) > 1e-6 ? clamp((pixel.x - a.x) / (b.x - a.x), 0.0, 1.0) : 0.0;
            float y = mix(a.y, b.y, t);
            return in.color * clamp(pixel.y - y + 0.5, 0.0, 1.0);
        }
        if (in.kind == 4) {
            // A picture with all corners rounded, faded by the color's alpha.
            constexpr sampler smooth(coord::normalized, filter::linear, address::clamp_to_edge);
            float4 texel = picture.sample(smooth, in.source);
            float2 halfSize = in.rect.zw * 0.5;
            float2 p = pixel - (in.rect.xy + halfSize);
            float r = min(in.radius, min(halfSize.x, halfSize.y));
            float2 q = abs(p) - halfSize + r;
            float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
            return texel * in.color.a * clamp(0.5 - d, 0.0, 1.0);
        }
        constexpr sampler texels(coord::pixel, filter::nearest);
        float4 texel = atlas.sample(texels, in.source);
        // Coverage in alpha (drawn in white), tinted; color glyphs as they
        // are, faded by the color's alpha (1 unless a fade multiplied it).
        return in.kind == 1 ? in.color * texel.a : texel * in.color.a;
    }
    """
}

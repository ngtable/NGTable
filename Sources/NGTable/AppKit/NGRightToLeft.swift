#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Right to left: the layout is mirrored (see `NGGridGeometry` and the layout
// metrics), and so is what each cell and column title draws, within its
// frame: shapes, icons, bars and indents trade sides, while every line of
// text moves whole, so it reads as written (Arabic and Hebrew included).
// Content is laid out left to right first (`contentLayoutDirection`), and
// the mirror puts the leading side at the right.

extension NGTableView {
    /// The direction content is laid out in before it is mirrored: always
    /// left to right (mirroring makes it right to left).
    var contentLayoutDirection: NGLayoutDirection { .leftToRight }

    /// Draws content with `draw`, then, right to left, mirrors it within `frame`.
    func appendMirrored(in frame: CGRect, clip: CGRect, renderer: NGMetalRenderer, scale: CGFloat,
                        to quads: inout [NGMetalQuad], _ draw: (inout [NGMetalQuad]) -> Void) {
        guard isRightToLeft else {
            draw(&quads)
            return
        }
        let start = quads.count
        let outer = renderer.textRuns
        renderer.textRuns = []
        draw(&quads)
        let runs = renderer.textRuns ?? []
        renderer.textRuns = outer
        Self.mirror(&quads, from: start, within: frame, clip: clip, runs: runs, scale: scale)
    }

    /// Mirrors quads from `start` within `frame`: lines of text (`runs`) move
    /// whole; everything else is reflected, rounded corners trading sides.
    /// Clips the size of the frame's visible part stay; narrower ones (a
    /// tag's title in its capsule) are reflected too.
    static func mirror(_ quads: inout [NGMetalQuad], from start: Int, within frame: CGRect, clip: CGRect,
                                   runs: [Range<Int>], scale: CGFloat) {
        guard start < quads.count else { return }
        let axis = Float((frame.minX + frame.maxX) * scale)
        let visible = NGMetalRenderer.pixels(clip, scale: scale)
        func mirrored(_ clip: SIMD4<Float>) -> SIMD4<Float> {
            if abs(clip.x - visible.x) < 0.5, abs(clip.z - visible.z) < 0.5 { return clip }
            return SIMD4(max(axis - clip.z, visible.x), clip.y, min(axis - clip.x, visible.z), clip.w)
        }
        var isText = [Bool](repeating: false, count: quads.count - start)
        for run in runs where run.lowerBound >= start && run.upperBound <= quads.count {
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
            for index in run {
                minX = min(minX, quads[index].rect.x)
                maxX = max(maxX, quads[index].rect.x + quads[index].rect.z)
            }
            let shift = axis - (minX + maxX)
            for index in run {
                quads[index].rect.x += shift
                quads[index].clip = mirrored(quads[index].clip)
                isText[index - start] = true
            }
        }
        for index in start..<quads.count where !isText[index - start] {
            quads[index].rect.x = axis - quads[index].rect.x - quads[index].rect.z
            quads[index].clip = mirrored(quads[index].clip)
            if quads[index].kind.x == 5 || quads[index].kind.x == 6 {
                // Segments: their ends are reflected too.
                quads[index].source.x = axis - quads[index].source.x
                quads[index].source.z = axis - quads[index].source.z
            }
            if quads[index].kind.x == 3 {
                // Rounded rectangles: min-x corners become max-x ones.
                let corners = UInt(quads[index].source.y)
                let swapped = (corners & 0b0101) << 1 | (corners & 0b1010) >> 1
                quads[index].source.y = Float(swapped)
            }
        }
    }
}
#endif

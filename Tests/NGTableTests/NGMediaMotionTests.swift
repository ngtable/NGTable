#if os(macOS)
import AppKit
import AVFoundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import NGTable

/// Videos and GIFs play under the pointer, drawn in place of the still picture.
@Suite("Media motion", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct NGMediaMotionTests {
    static func solidImage(_ color: CGColor, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A GIF of a red, a green and a blue frame.
    static func makeGIF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGTableTests-motion-\(UUID()).gif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            CGImageDestinationAddImage(destination, solidImage(color, width: 80, height: 60),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A second of solid blue video.
    static func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGTableTests-motion-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            for row in 0..<96 {
                for column in 0..<160 {
                    let pixel = base + row * CVPixelBufferGetBytesPerRow(pixels) + column * 4
                    pixel[0] = 255; pixel[1] = 0; pixel[2] = 0; pixel[3] = 255   // BGRA blue
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @MainActor
    final class Data: NGTableViewDataSource {
        var media: [NGMedia] = []
        func numberOfRows(in tableView: NGTableView) -> Int { media.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .media(media[row]) }
    }

    /// The color at the middle of a row's thumbnail in a snapshot (sRGB 0...255).
    private func thumbnailColor(_ table: NGTableView, row: Int) throws -> (red: Int, green: Int, blue: Int) {
        let image = try #require(table.metalSnapshot())
        let scale = table.displayScale
        let cell = try #require(table.frameOfCell(row: row, columnID: "media"))
        let center = table.mediaThumbnailFrame(of: table.data(row), inCell: cell)
        let pixels = NGSnapshot.pixels(of: image)
        let x = Int(center.midX * scale), y = Int(center.midY * scale)
        let offset = (y * image.width + x) * 4
        return (Int(pixels[offset + 2]), Int(pixels[offset + 1]), Int(pixels[offset]))
    }

    @Test func gifAndVideoPlayUnderThePointer() async throws {
        let still = try NGFrameSnapshotTests.testPicture(named: "motion-still", width: 200, height: 130, hue: 0.15)
        let data = Data()
        data.media = [
            NGMedia(image: still, motion: .animatedImage(try Self.makeGIF()), lines: [.init("GIF", style: .title)]),
            NGMedia(image: still, motion: .video(try await Self.makeVideo()), lines: [.init("Video", style: .title)]),
        ]
        let frame = NSRect(x: 0, y: 0, width: 400, height: 260)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.scaleForTesting = 2
        table.rowHeight = 80
        table.columns = [.column(NGTableColumn("media", title: "Media", width: 380))]
        window.contentView = table
        table.dataSource = data
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((window, data)) {} }

        for (row, expected) in [(0, (red: 255, green: 0, blue: 0)), (1, (red: 0, green: 0, blue: 255))] {
            let cell = try #require(table.frameOfCell(row: row, columnID: "media"))
            // The test window isn't on screen: its pointer is set, not read.
            table.pointerLocationForTesting = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
            table.updateHoveredCellFromPointer()
            let player = try #require(table.mediaPlayer)
            for _ in 0..<300 where player.texture == nil {
                player.step()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(player.texture != nil, "row \(row) never played")
            // A video frame's Core Video texture goes with it, for the frames that draw it to keep.
            #expect((player.textureOwner != nil) == (row == 1))
            let color = try thumbnailColor(table, row: row)
            #expect(abs(color.red - expected.red) < 40 && abs(color.green - expected.green) < 40 && abs(color.blue - expected.blue) < 40,
                    "row \(row): \(color)")
        }
        // The row under the pointer is reloaded: the same video keeps playing
        // (in the new cell), another value plays instead.
        let playing = try #require(table.mediaPlayer)
        table.reloadData()
        try await eventually { table.mediaPlayer === playing && playing.cell === table.visibleCell(row: 1, columnID: "media") }
        #expect(table.mediaPlayer === playing)
        #expect(playing.cell === table.visibleCell(row: 1, columnID: "media"))
        data.media[1] = data.media[0]
        table.reloadData()
        try await eventually { table.mediaPlayer !== playing && table.mediaPlayer?.media == data.media[0] }
        #expect(table.mediaPlayer !== playing)
        #expect(table.mediaPlayer?.media == data.media[0])
        // Away from the cells: nothing plays, the still shows again.
        table.pointerLocationForTesting = NSPoint(x: -10, y: -10)
        table.updateHoveredCellFromPointer()
        #expect(table.mediaPlayer == nil)
    }

    /// GIF frames are decoded at the thumbnail's size, kept for the next time
    /// the pointer comes back, and not decoded at all once the pointer left.
    @Test func gifFramesAreSmallKeptAndCancellable() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gif = try Self.makeGIF()
        let frames = NGMediaPlayer.gifFrames(of: gif, width: 40, height: 30, device: device)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.texture.width == 40 && $0.texture.height == 30 })
        // A cancelled decoding gives up before the first frame.
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return NGMediaPlayer.gifFrames(of: gif, width: 40, height: 30, device: device).count
        }.value
        #expect(cancelled == 0)
        // Played once, it is played again from the decoded frames.
        let recent = NGRecentGIFs()
        let key = NGMediaPlayer.GIFKey(url: gif, width: 40, height: 30)
        recent.insert(frames, for: key)
        #expect(recent.frames(for: key)?.count == 3)
        recent.memoryLimit = 40 * 30 * 4 * 2   // Less than three frames.
        #expect(recent.frames(for: key) == nil)
        #expect(recent.cost == 0)
    }
}

extension NGTableView {
    /// The media value of a visible row's first cell (for the tests above).
    func data(_ row: Int) -> NGMedia {
        guard case .media(let media) = dataSource?.tableView(self, valueFor: tableColumns[0], row: row) else { return NGMedia(image: nil) }
        return media
    }
}
#endif

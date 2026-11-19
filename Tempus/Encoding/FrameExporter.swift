@preconcurrency import AVFoundation
import CoreGraphics
import VideoToolbox

/// Turns a screenshot session's HEIC frames into an MP4, one second per frame.
nonisolated enum FrameExporter {
    static let framesPerSecond: Int32 = 1

    static func export(frames: [URL], to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !frames.isEmpty else { throw TempusError.noFrames }

        // Size the video to the largest frame (read from headers, no decoding).
        var width = 0, height = 0
        for frame in frames {
            if let size = Stills.pixelSize(at: frame), size.width * size.height > width * height {
                (width, height) = size
            }
        }
        guard width > 0 else { throw TempusError.noFrames }
        width += width % 2
        height += height % 2

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        guard let settings = [VideoCodec.hevc, .h264].lazy
            .map({ outputSettings(codec: $0, width: width, height: height) })
            .first(where: { writer.canApply(outputSettings: $0, forMediaType: .video) })
        else { throw TempusError.noEncoder }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.startWriting() else { throw writer.error ?? TempusError.noEncoder }
        writer.startSession(atSourceTime: .zero)

        do {
            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let image = Stills.loadImage(at: frame) else { continue }
                guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? TempusError.exportFailed("No pixel buffer pool") }
                let buffer = try render(image, width: width, height: height, pool: pool)
                let time = CMTime(value: CMTimeValue(index), timescale: framesPerSecond)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? TempusError.exportFailed("A frame could not be encoded")
                }
                progress(Double(index + 1) / Double(frames.count))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames.count), timescale: framesPerSecond))
            await writer.finishWriting()
            if writer.status == .failed { throw writer.error ?? TempusError.exportFailed("Encoding failed") }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func outputSettings(codec: VideoCodec, width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // Constant quality: each frame is a fresh screenshot, so let the
                // encoder spend what it needs to keep text sharp.
                AVVideoQualityKey: 0.8,
                AVVideoExpectedSourceFrameRateKey: Int(framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: 2,
                AVVideoProfileLevelKey: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
    }

    /// Draws `image` centred on black, scaled down (never up) to fit.
    private static func render(_ image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let buffer = output else { throw TempusError.exportFailed("Out of memory") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw TempusError.exportFailed("Could not draw a frame") }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(1, Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawWidth = (Double(image.width) * scale).rounded()
        let drawHeight = (Double(image.height) * scale).rounded()
        // Integer placement avoids softening every pixel by a half-pixel offset.
        let rect = CGRect(x: ((Double(width) - drawWidth) / 2).rounded(.down),
                          y: ((Double(height) - drawHeight) / 2).rounded(.down),
                          width: drawWidth, height: drawHeight)
        context.interpolationQuality = scale < 1 ? .high : .none
        context.draw(image, in: rect)
        return buffer
    }
}

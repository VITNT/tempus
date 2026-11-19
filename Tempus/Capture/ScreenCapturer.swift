import CoreMedia
@preconcurrency import ScreenCaptureKit

/// Wraps one ScreenCaptureKit source: a low-rate `SCStream` for video mode and
/// one-shot `SCScreenshotManager` grabs for screenshot mode.
nonisolated final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let filter: SCContentFilter
    let pixelWidth: Int
    let pixelHeight: Int

    // Touched only from the main actor (start/stop) or the capture queue (callbacks).
    private var stream: SCStream?
    private var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    private var onStop: (@Sendable (Error) -> Void)?

    init(filter: SCContentFilter) {
        self.filter = filter
        let size = SourceCatalog.pixelSize(of: filter)
        pixelWidth = max(2, size.width)
        pixelHeight = max(2, size.height)
    }

    /// Starts delivering frames no more often than `frameInterval` seconds.
    /// ScreenCaptureKit scales into `width × height` on the GPU (letterboxing if
    /// a window changes shape) and only sends frames when the content changes.
    func startStream(width: Int, height: Int, frameInterval: Double,
                     onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
                     onStop: @escaping @Sendable (Error) -> Void) async throws {
        self.onFrame = onFrame
        self.onStop = onStop
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(seconds: frameInterval, preferredTimescale: 600)
        // 4:2:0 YUV is what the hardware encoder consumes, so frames go
        // straight from the GPU to VideoToolbox without a conversion.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = true
        config.queueDepth = 4
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: CaptureQueue.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stopStream() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// A full-resolution still of the source.
    func screenshot() async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = true
        config.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: SCStreamOutput / SCStreamDelegate (capture queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

@preconcurrency import AVFoundation
import VideoToolbox

/// Live video-mode encoder: hardware HEVC (or H.264) into a fragmented MP4.
///
/// Fragments are flushed every 2 seconds, so if Tempus quits unexpectedly the
/// file is still playable up to the last fragment. Frames are placed on a
/// 30 fps timeline by `SlotScheduler`; between captures the previous frame
/// simply stays on screen, so a static screen costs almost nothing.
///
/// Not thread-safe: use only on `CaptureQueue.queue`.
nonisolated final class TimelapseWriter: @unchecked Sendable {
    let plan: VideoPlan
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var scheduler: SlotScheduler
    private(set) var framesWritten = 0
    private var finished = false

    /// Tries each size × codec plan, best first, until the encoder accepts one.
    static func create(url: URL, sourceWidth: Int, sourceHeight: Int, speed: Int, after rejected: VideoPlan? = nil) throws -> TimelapseWriter {
        var plans = VideoPlan.candidates(width: sourceWidth, height: sourceHeight, speed: speed)
        if let rejected, let index = plans.firstIndex(of: rejected) {
            plans.removeFirst(index + 1)
        }
        for plan in plans {
            try? FileManager.default.removeItem(at: url)
            if let writer = try? TimelapseWriter(url: url, plan: plan, speed: speed) { return writer }
        }
        throw TempusError.noEncoder
    }

    private init(url: URL, plan: VideoPlan, speed: Int) throws {
        self.url = url
        self.plan = plan
        scheduler = SlotScheduler(speed: speed)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let settings = Self.outputSettings(for: plan)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw TempusError.noEncoder }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw TempusError.noEncoder }
        writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw writer.error ?? TempusError.noEncoder }
    }

    static func outputSettings(for plan: VideoPlan) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.bitrate,
            AVVideoExpectedSourceFrameRateKey: VideoPlan.outputFPS,
            AVVideoMaxKeyFrameIntervalDurationKey: 4,
            AVVideoAllowFrameReorderingKey: true,
        ]
        compression[AVVideoProfileLevelKey] = plan.codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel as String
            : AVVideoProfileLevelH264HighAutoLevel
        return [
            AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    /// True once the encoder has failed before writing anything, meaning the
    /// caller should retry with a smaller or simpler plan.
    var rejectedPlan: Bool { writer.status == .failed && framesWritten == 0 }

    var status: AVAssetWriter.Status { writer.status }
    var error: Error? { writer.error }
    var bytes: Int64 { SessionFiles.fileSize(url) }

    func videoSeconds(at activeSeconds: Double) -> Double {
        scheduler.videoSeconds(at: activeSeconds)
    }

    /// Appends a frame captured at `activeSeconds`. Returns false if the frame
    /// was dropped (slot already filled, encoder busy, or writer failed).
    @discardableResult
    func append(_ pixelBuffer: CVPixelBuffer, at activeSeconds: Double) -> Bool {
        guard !finished, writer.status == .writing, input.isReadyForMoreMediaData else { return false }
        var next = scheduler
        guard let slot = next.claim(at: activeSeconds) else { return false }
        let time = CMTime(value: slot, timescale: CMTimeScale(VideoPlan.outputFPS))
        if scheduler.firstSlot == nil { writer.startSession(atSourceTime: time) }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else { return false }
        scheduler = next
        framesWritten += 1
        return true
    }

    /// Closes the file. A session with no frames leaves no file behind.
    func finish(at activeSeconds: Double) async throws {
        guard !finished else { return }
        finished = true
        guard writer.status == .writing, let end = scheduler.endSlot(at: activeSeconds) else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            return
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: end, timescale: CMTimeScale(VideoPlan.outputFPS)))
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? TempusError.noEncoder }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        if writer.status == .writing { writer.cancelWriting() }
    }
}

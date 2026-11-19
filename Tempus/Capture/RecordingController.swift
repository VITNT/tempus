import CoreImage
import Observation
@preconcurrency import ScreenCaptureKit
import SwiftData

/// Video mode's per-frame work, done on the capture queue: append to the
/// writer and refresh the thumbnail every few seconds.
nonisolated final class VideoPipeline: @unchecked Sendable {
    struct Stats: Sendable {
        var plan: VideoPlan
        var frames: Int
        var videoSeconds: Double
        var bytes: Int64
    }

    private var writer: TimelapseWriter
    private let clock: ActiveClock
    private let source: (width: Int, height: Int)
    private let speed: Int
    private let thumbnailURL: URL
    private let onThumbnail: @Sendable (Unchecked<CGImage>) -> Void
    private var lastThumbnailAt = -Double.infinity

    var plan: VideoPlan { writer.plan }

    init(sessionID: UUID, sourceWidth: Int, sourceHeight: Int, speed: Int, clock: ActiveClock,
         onThumbnail: @escaping @Sendable (Unchecked<CGImage>) -> Void) throws {
        writer = try TimelapseWriter.create(url: SessionFiles.videoURL(for: sessionID),
                                            sourceWidth: sourceWidth, sourceHeight: sourceHeight, speed: speed)
        source = (sourceWidth, sourceHeight)
        self.speed = speed
        self.clock = clock
        self.thumbnailURL = SessionFiles.thumbnailURL(for: sessionID)
        self.onThumbnail = onThumbnail
    }

    func consume(_ pixelBuffer: CVPixelBuffer) {
        guard clock.isRunning else { return }
        let now = clock.seconds
        if !writer.append(pixelBuffer, at: now), writer.rejectedPlan,
           let fallback = try? TimelapseWriter.create(url: writer.url, sourceWidth: source.width, sourceHeight: source.height,
                                                     speed: speed, after: writer.plan) {
            // The hardware refused this size or codec once frames started; step down.
            writer = fallback
            writer.append(pixelBuffer, at: now)
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastThumbnailAt >= RecordingController.checkpointInterval,
           let thumbnail = Stills.thumbnail(of: CIImage(cvPixelBuffer: pixelBuffer)) {
            lastThumbnailAt = uptime
            Stills.writeJPEG(thumbnail, to: thumbnailURL)
            onThumbnail(Unchecked(thumbnail))
        }
    }

    func stats() -> Stats {
        Stats(plan: writer.plan, frames: writer.framesWritten, videoSeconds: writer.videoSeconds(at: clock.seconds), bytes: writer.bytes)
    }

    func finish() async throws {
        try await writer.finish(at: clock.seconds)
    }

    func cancel() {
        writer.cancel()
    }
}

/// Runs one recording: owns the capture source, the clock and (in video mode)
/// the encoder, and keeps the `Session` row up to date.
@Observable
final class RecordingController {
    nonisolated static let checkpointInterval = 5.0

    let session: Session
    private(set) var source: CaptureSource
    private(set) var preview: CGImage?
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    let clock: ActiveClock

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var screen: ScreenCapturer?
    @ObservationIgnored private var camera: CameraCapturer?
    @ObservationIgnored private var pipeline: VideoPipeline?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var sourceLost = false

    var isRecording: Bool { session.status == .recording }

    init(session: Session, source: CaptureSource, context: ModelContext) {
        self.session = session
        self.source = source
        self.context = context
        clock = ActiveClock(startingAt: session.trackedSeconds)
    }

    // MARK: Lifecycle

    func start() async throws {
        try SessionFiles.prepare(for: session.id)
        try await connect()
        if session.mode == .video {
            let size = camera.map { ($0.pixelWidth, $0.pixelHeight) } ?? (screen!.pixelWidth, screen!.pixelHeight)
            let pipeline = try VideoPipeline(
                sessionID: session.id, sourceWidth: size.0, sourceHeight: size.1, speed: session.speed, clock: clock,
                onThumbnail: { [weak self] image in Task { @MainActor in self?.showPreview(image.value) } })
            self.pipeline = pipeline
            let plan = pipeline.plan
            session.videoCodec = plan.codec.rawValue
            session.videoWidth = plan.width
            session.videoHeight = plan.height
            session.videoBitrate = plan.bitrate
        }
        try await begin()
    }

    func pause() async {
        guard session.status == .recording else { return }
        clock.pause()
        loopTask?.cancel()
        loopTask = nil
        await screen?.stopStream()
        await camera?.stop()
        session.status = .paused
        await checkpoint()
    }

    func resume() async {
        guard session.status == .paused, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            if sourceLost {
                // The window or camera went away; find it again before restarting.
                screen = nil
                camera = nil
                try await connect()
                sourceLost = false
            }
            try await begin()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Finishes the recording and marks the session complete.
    func stop(name: String) async {
        isBusy = true
        defer { isBusy = false }
        await pause()
        if let pipeline {
            // Let any frame already on the capture queue land before closing the file.
            await CaptureQueue.run {}
            do {
                try await pipeline.finish()
            } catch {
                errorMessage = "Could not finish the video: \(error.localizedDescription)"
            }
            await checkpoint()
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.name = trimmed.isEmpty ? "Untitled Timelapse" : trimmed
        session.status = .complete
        session.endedAt = .now
        save()
    }

    /// Abandons the recording (the session is being deleted).
    func cancel() {
        clock.pause()
        loopTask?.cancel()
        let screen = screen.map(Unchecked.init), camera = camera.map(Unchecked.init), pipeline = pipeline.map(Unchecked.init)
        Task {
            await screen?.value.stopStream()
            await camera?.value.stop()
            CaptureQueue.queue.async { pipeline?.value.cancel() }
        }
    }

    // MARK: Capture

    /// Opens the capture source (screen filter or camera).
    private func connect() async throws {
        switch source.target {
        case .camera(let id):
            guard await SourceCatalog.cameraAccess() else { throw TempusError.cameraAccessDenied }
            camera = try CameraCapturer(deviceID: id) { [weak self] error in
                Task { @MainActor in await self?.handleSourceLost(error) }
            }
        case .display, .window:
            screen = ScreenCapturer(filter: try await SourceCatalog.filter(for: source))
        }
    }

    /// Starts frames flowing and the clock running.
    private func begin() async throws {
        clock.resume()
        session.status = .recording
        do {
            switch session.mode {
            case .video:
                guard let pipeline else { return }
                let sink: @Sendable (CVPixelBuffer) -> Void = { pipeline.consume($0) }
                if let camera {
                    await camera.start(onFrame: sink)
                } else if let screen {
                    try await screen.startStream(
                        width: pipeline.plan.width, height: pipeline.plan.height,
                        frameInterval: VideoPlan.frameInterval(speed: session.speed),
                        onFrame: sink,
                        onStop: { [weak self] error in Task { @MainActor in await self?.handleSourceLost(error) } })
                }
                loopTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(Self.checkpointInterval))
                        guard !Task.isCancelled else { return }
                        await self?.checkpoint()
                    }
                }
            case .screenshots:
                await camera?.start()
                let interval = Duration.seconds(session.intervalSeconds)
                loopTask = Task { [weak self] in
                    // A camera needs a moment to deliver its first frame.
                    if self?.camera != nil { try? await Task.sleep(for: .seconds(1)) }
                    let clock = ContinuousClock()
                    var next = clock.now
                    while !Task.isCancelled {
                        await self?.captureScreenshot()
                        next = next.advanced(by: interval)
                        try? await Task.sleep(until: next, clock: clock)
                    }
                }
            }
        } catch {
            clock.pause()
            session.status = .paused
            throw error
        }
        save()
    }

    private func captureScreenshot() async {
        guard session.status == .recording else { return }
        do {
            let image: CIImage
            if let screen {
                image = CIImage(cgImage: try await screen.screenshot())
            } else if let frame = camera?.latestFrame() {
                image = CIImage(cvPixelBuffer: frame)
            } else {
                throw TempusError.noCameraFrame
            }
            guard session.status == .recording else { return }
            let index = session.frameCount + 1
            let frameURL = SessionFiles.frameURL(for: session.id, index: index)
            let thumbnailURL = SessionFiles.thumbnailURL(for: session.id)
            let boxed = Unchecked(image)
            let thumbnail = try await Task.detached(priority: .userInitiated) {
                try Stills.writeHEIC(boxed.value, to: frameURL)
                let thumbnail = Stills.thumbnail(of: boxed.value)
                if let thumbnail { Stills.writeJPEG(thumbnail, to: thumbnailURL) }
                return thumbnail.map(Unchecked.init)
            }.value
            session.frameCount = index
            session.trackedSeconds = clock.seconds
            if let thumbnail { showPreview(thumbnail.value) }
            errorMessage = nil
            save()
        } catch {
            if case TempusError.noCameraFrame = error, session.frameCount == 0 { return }
            errorMessage = error.localizedDescription
        }
    }

    private func showPreview(_ image: CGImage) {
        preview = image
        session.thumbnailVersion += 1
    }

    private func handleSourceLost(_ error: Error) async {
        guard session.status != .complete else { return }
        sourceLost = true
        await pause()
        let reason = (error as? TempusError)?.errorDescription ?? "Capture of “\(source.label)” ended."
        errorMessage = "\(reason) Select Resume to reconnect."
    }

    /// Writes running stats to the session row.
    private func checkpoint() async {
        session.trackedSeconds = clock.seconds
        if let pipeline {
            let boxed = Unchecked(pipeline)
            let stats = await CaptureQueue.run { boxed.value.stats() }
            session.frameCount = stats.frames
            session.videoSeconds = stats.videoSeconds
            session.videoBytes = stats.bytes
            session.videoCodec = stats.plan.codec.rawValue
            session.videoWidth = stats.plan.width
            session.videoHeight = stats.plan.height
            session.videoBitrate = stats.plan.bitrate
        }
        save()
    }

    private func save() {
        try? context.save()
    }
}

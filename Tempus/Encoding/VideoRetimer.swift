@preconcurrency import AVFoundation

/// Re-times a finished video-mode timelapse to a different playback speed.
///
/// The recording stays untouched; this writes a new file that plays `rate`
/// times as fast (2 = twice as fast, 0.5 = half speed), resampled to 30 fps, so
/// speeding up drops frames and slowing down holds each frame on screen longer.
nonisolated enum VideoRetimer {
    static func export(from source: URL, to url: URL, rate: Double,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TempusError.exportFailed("The recording has no video")
        }
        let range = try await track.load(.timeRange)
        guard range.duration.seconds > 0 else { throw TempusError.exportFailed("The recording is empty") }

        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TempusError.exportFailed("Could not prepare the video")
        }
        try output.insertTimeRange(range, of: track, at: .zero)
        output.preferredTransform = try await track.load(.preferredTransform)
        guard rate > 0 else { throw TempusError.exportFailed("Invalid playback speed") }
        let scaled = CMTime(seconds: range.duration.seconds / rate, preferredTimescale: 600)
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: scaled)

        var configuration = try await AVVideoComposition.Configuration(for: composition)
        configuration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VideoPlan.outputFPS))

        var preset: String?
        for candidate in [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality] {
            if await AVAssetExportSession.compatibility(ofExportPreset: candidate, with: composition, outputFileType: .mp4) {
                preset = candidate
                break
            }
        }
        guard let preset, let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw TempusError.noEncoder
        }
        session.videoComposition = AVVideoComposition(configuration: configuration)
        session.shouldOptimizeForNetworkUse = true

        try? FileManager.default.removeItem(at: url)
        // The export session is only read here (its state stream), never mutated.
        let watched = Unchecked(session)
        let monitor = Task {
            for await state in watched.value.states(updateInterval: 0.1) {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: url, as: .mp4)
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

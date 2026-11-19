import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Tempus

/// End-to-end checks against the real hardware encoder.
struct EncodingTests {
    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tempus-test-\(UUID().uuidString).\(ext)")
    }

    /// A 4:2:0 frame filled with a flat colour, like ScreenCaptureKit delivers.
    private func yuvFrame(width: Int, height: Int, luma: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let frame = buffer!
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(frame, 0), Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(frame, 0) * height)
        memset(CVPixelBufferGetBaseAddressOfPlane(frame, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(frame, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(frame, [])
        return frame
    }

    @Test func liveWriterProducesHEVCAtTheRightLength() async throws {
        let url = temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        // 1440p source at 60×: one frame per 2 s of "recording".
        let writer = try TimelapseWriter.create(url: url, sourceWidth: 2560, sourceHeight: 1440, speed: 60)
        #expect(writer.plan.codec == .hevc)
        #expect(writer.plan.width == 2560)

        var appended = 0
        for index in 0..<90 {
            let frame = yuvFrame(width: 2560, height: 1440, luma: UInt8(16 + index % 200))
            // Real-time input: wait for the encoder like the capture queue would drop.
            var attempts = 0
            while !writer.append(frame, at: Double(index) * 2), attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            appended = writer.framesWritten
        }
        #expect(appended == 90)
        try await writer.finish(at: 180)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3.0) < 0.05, "180 s at 60× should be 3 s, got \(duration)")
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 2560, height: 1440))
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
    }

    @Test func writerWithNoFramesLeavesNoFile() async throws {
        let url = temporaryURL("mp4")
        let writer = try TimelapseWriter.create(url: url, sourceWidth: 1280, sourceHeight: 800, speed: 60)
        try await writer.finish(at: 10)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func screenshotsRoundTripThroughHEICAndExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tempus-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Three frames; the middle one is a different size and gets letterboxed.
        let sizes = [CGSize(width: 1600, height: 1000), CGSize(width: 1200, height: 1000), CGSize(width: 1600, height: 1000)]
        var frames: [URL] = []
        for (index, size) in sizes.enumerated() {
            let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: Double(index) / 3)).cropped(to: CGRect(origin: .zero, size: size))
            let url = folder.appending(path: String(format: "%06d.heic", index + 1))
            try Stills.writeHEIC(image, to: url)
            #expect(Stills.pixelSize(at: url)! == (Int(size.width), Int(size.height)))
            frames.append(url)
        }

        let output = temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let progress = ProgressRecorder()
        try await FrameExporter.export(frames: frames, to: output) { progress.record($0) }

        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.duration).seconds == 3)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 1600, height: 1000))
        #expect(progress.last == 1)
    }

    @Test func thumbnailIsDownscaled() throws {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 3200, height: 2000))
        let thumbnail = try #require(Stills.thumbnail(of: image))
        #expect(thumbnail.width == 640)
        #expect(thumbnail.height == 400)
    }
}

nonisolated private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var last: Double { lock.withLock { value } }
    func record(_ next: Double) { lock.withLock { value = next } }
}

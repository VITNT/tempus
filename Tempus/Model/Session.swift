import Foundation
import SwiftData

enum SessionStatus: String, Codable, Sendable {
    case recording, paused, complete
}

enum CaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case screenshots, video
    var id: String { rawValue }
}

enum SourceKind: String, Codable, Sendable {
    case display, window, camera

    var isScreen: Bool { self != .camera }
}

/// One timelapse. Media lives on disk in `SessionFiles.folder(for:)`; this row
/// holds metadata and running stats only.
@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var endedAt: Date?
    var statusRaw: String
    var modeRaw: String
    var sourceKindRaw: String
    var sourceLabel: String
    /// Screenshot mode: seconds between captures.
    var intervalSeconds: Int
    /// Video mode: playback speed multiplier (60 = one hour becomes one minute).
    var speed: Int
    /// Recording time with pauses excluded.
    var trackedSeconds: Double
    /// Screenshots saved, or video frames written.
    var frameCount: Int
    var videoBytes: Int64
    var videoSeconds: Double
    var videoCodec: String?
    var videoWidth: Int
    var videoHeight: Int
    var videoBitrate: Int
    /// Bumped whenever the thumbnail file is rewritten, so views reload it.
    var thumbnailVersion: Int

    init(name: String, mode: CaptureMode, sourceKind: SourceKind, sourceLabel: String, intervalSeconds: Int, speed: Int) {
        id = UUID()
        self.name = name
        createdAt = .now
        statusRaw = SessionStatus.recording.rawValue
        modeRaw = mode.rawValue
        sourceKindRaw = sourceKind.rawValue
        self.sourceLabel = sourceLabel
        self.intervalSeconds = intervalSeconds
        self.speed = speed
        trackedSeconds = 0
        frameCount = 0
        videoBytes = 0
        videoSeconds = 0
        videoWidth = 0
        videoHeight = 0
        videoBitrate = 0
        thumbnailVersion = 0
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .complete }
        set { statusRaw = newValue.rawValue }
    }

    var mode: CaptureMode {
        get { CaptureMode(rawValue: modeRaw) ?? .screenshots }
        set { modeRaw = newValue.rawValue }
    }

    var sourceKind: SourceKind {
        get { SourceKind(rawValue: sourceKindRaw) ?? .display }
        set { sourceKindRaw = newValue.rawValue }
    }

    static func defaultName(on date: Date = .now) -> String {
        "Timelapse \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

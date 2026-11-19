import Foundation

nonisolated enum VideoCodec: String, Sendable {
    case hevc, h264

    var displayName: String { self == .hevc ? "HEVC" : "H.264" }

    /// Bits per pixel per frame that look high quality for screen content.
    /// HEVC needs roughly 35–40% fewer bits than H.264 for the same result.
    var qualityBitsPerPixel: Double { self == .hevc ? 0.045 : 0.07 }
}

/// Encoder size and bitrate for a live video timelapse.
nonisolated struct VideoPlan: Equatable, Sendable {
    static let outputFPS = 30
    static let speedOptions = [5, 10, 30, 60, 120, 300]
    static let defaultSpeed = 60
    /// Hard ceiling on file size: 500 MB per hour of recorded (real) time.
    static let maxBytesPerHour = 500_000_000.0
    /// VBR encoders overshoot a little and MP4 adds container overhead.
    static let budgetHeadroom = 0.85
    static let minBitrate = 1_500_000

    var codec: VideoCodec
    var width: Int
    var height: Int
    var bitrate: Int
    /// True when the 500 MB/hour cap, not the quality target, set the bitrate.
    var budgetLimited: Bool

    /// Seconds of output video per hour of recording.
    static func videoSecondsPerHour(speed: Int) -> Double {
        3600 / Double(speed)
    }

    /// Seconds of real time between captured frames.
    static func frameInterval(speed: Int) -> Double {
        Double(speed) / Double(outputFPS)
    }

    static func bitrate(codec: VideoCodec, width: Int, height: Int, speed: Int) -> (bitrate: Int, budgetLimited: Bool) {
        let quality = Double(width * height * outputFPS) * codec.qualityBitsPerPixel
        let budget = maxBytesPerHour * 8 * budgetHeadroom / videoSecondsPerHour(speed: speed)
        let bitrate = Int(max(Double(minBitrate), min(quality, budget)).rounded())
        return (bitrate, budget < quality)
    }

    /// Worst-case megabytes per hour of recording (VBR usually lands well under).
    static func estimatedMegabytesPerHour(bitrate: Int, speed: Int) -> Double {
        Double(bitrate) * videoSecondsPerHour(speed: speed) / 8 / 1_000_000
    }

    /// Native size first, then 4K, 1440p and 1080p caps (rotated for portrait
    /// sources), with even dimensions and duplicates removed.
    static func candidateSizes(width: Int, height: Int) -> [(width: Int, height: Int)] {
        let portrait = height > width
        let caps: [(Double, Double)] = [(.infinity, .infinity), (3840, 2160), (2560, 1440), (1920, 1080)]
        var sizes: [(width: Int, height: Int)] = []
        for (capW, capH) in caps {
            let (maxW, maxH) = portrait ? (capH, capW) : (capW, capH)
            let scale = min(1, maxW / Double(width), maxH / Double(height))
            let size = (width: even(Int((Double(width) * scale).rounded())), height: even(Int((Double(height) * scale).rounded())))
            if !sizes.contains(where: { $0 == size }) { sizes.append(size) }
        }
        return sizes
    }

    /// Every size × codec combination to try, best first.
    static func candidates(width: Int, height: Int, speed: Int) -> [VideoPlan] {
        candidateSizes(width: width, height: height).flatMap { size in
            [VideoCodec.hevc, .h264].map { codec in
                let (bitrate, limited) = Self.bitrate(codec: codec, width: size.width, height: size.height, speed: speed)
                return VideoPlan(codec: codec, width: size.width, height: size.height, bitrate: bitrate, budgetLimited: limited)
            }
        }
    }

    private static func even(_ value: Int) -> Int {
        max(2, value - value % 2)
    }
}

/// Maps recording time (pauses excluded) onto output frame slots.
///
/// A frame captured at `t` seconds lands at slot `floor(t / speed × 30)`, so a
/// 60× recording of one hour plays back as exactly one minute. Frames that
/// would land on an already-filled slot are dropped; a gap (static screen,
/// slow source) simply lets the previous frame stay on screen longer.
nonisolated struct SlotScheduler: Sendable {
    let speed: Int
    private(set) var firstSlot: Int64?
    private(set) var lastSlot: Int64?

    init(speed: Int) { self.speed = speed }

    func slot(at activeSeconds: Double) -> Int64 {
        // Multiply before dividing, plus a hair of tolerance, so a frame on an
        // exact slot boundary (2 s at 60×) isn't floored into the previous slot.
        Int64((max(0, activeSeconds) * Double(VideoPlan.outputFPS) / Double(speed) + 1e-9).rounded(.down))
    }

    /// The slot to write a frame captured at `activeSeconds` into, or nil to drop it.
    mutating func claim(at activeSeconds: Double) -> Int64? {
        let slot = slot(at: activeSeconds)
        if let lastSlot, slot <= lastSlot { return nil }
        if firstSlot == nil { firstSlot = slot }
        lastSlot = slot
        return slot
    }

    /// Where the video should end: at least one frame after the last one, and
    /// extended to `activeSeconds` so a static ending still lasts the right time.
    func endSlot(at activeSeconds: Double) -> Int64? {
        guard let lastSlot else { return nil }
        return max(lastSlot + 1, slot(at: activeSeconds))
    }

    func videoSeconds(at activeSeconds: Double) -> Double {
        guard let firstSlot, let end = endSlot(at: activeSeconds) else { return 0 }
        return Double(end - firstSlot) / Double(VideoPlan.outputFPS)
    }
}

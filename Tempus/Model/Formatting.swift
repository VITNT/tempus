import Foundation

nonisolated enum Format {
    /// `01:02:03`
    static func clock(_ totalSeconds: Double) -> String {
        let total = max(0, Int(totalSeconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// `45 sec`, `12 min`, `2h 5m`
    static func tracked(_ totalSeconds: Double) -> String {
        if totalSeconds < 60 { return "\(max(1, Int(totalSeconds.rounded()))) sec" }
        let total = Int(totalSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }

    /// Video length: `42 sec` under a minute, otherwise `m:ss`.
    static func videoLength(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole) sec" : String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Live recorder readout, always `m:ss`.
    static func runningVideoLength(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func bytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if bytes < 1_000_000 { return "\(max(1, Int((value / 1000).rounded()))) KB" }
        if bytes < 1_000_000_000 {
            return bytes < 10_000_000 ? String(format: "%.1f MB", value / 1_000_000) : "\(Int((value / 1_000_000).rounded())) MB"
        }
        return String(format: "%.2f GB", value / 1_000_000_000)
    }

    /// Output length for one hour of recording: `1 min`, `12 sec`, `2.5 min`.
    static func speedOutput(_ speed: Int) -> String {
        let seconds = VideoPlan.videoSecondsPerHour(speed: speed)
        if seconds >= 60 {
            let minutes = (seconds / 6).rounded() / 10
            return minutes == minutes.rounded() ? "\(Int(minutes)) min" : "\(minutes) min"
        }
        return "\(Int(seconds.rounded())) sec"
    }

    static func speedSummary(_ speed: Int) -> String {
        "1 hr → \(speedOutput(speed))"
    }

    /// Relative playback rate: `0.25×`, `1×`, `1.5×`.
    static func rate(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    static func interval(_ seconds: Int) -> String {
        if seconds < 60 { return "Every \(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
    }

    static func filename(_ value: String) -> String {
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .filter { !$0.isEmpty }
        let joined = pieces.joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return joined.isEmpty ? "timelapse" : joined
    }
}

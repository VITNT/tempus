import Foundation
import Synchronization

nonisolated enum Preferences {
    static let interval = "tempus-interval"
    static let mode = "tempus-mode"
    static let speed = "tempus-speed"
    static let intervalOptions = [5, 15, 30, 60, 120]
    static let defaultInterval = 60
}

nonisolated enum TempusError: LocalizedError {
    case noEncoder
    case sourceUnavailable(String)
    case screenAccessDenied
    case cameraAccessDenied
    case noFrames
    case noCameraFrame
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEncoder: "This Mac has no video encoder that can record this source."
        case .sourceUnavailable(let label): "“\(label)” is no longer available. Reopen it, or stop this timelapse."
        case .screenAccessDenied: "Tempus needs Screen Recording access. Turn it on in System Settings › Privacy & Security, then try again."
        case .cameraAccessDenied: "Tempus needs Camera access. Turn it on in System Settings › Privacy & Security, then try again."
        case .noFrames: "This session has no screenshots."
        case .noCameraFrame: "The camera hasn’t delivered a frame yet."
        case .exportFailed(let reason): "Could not export the video: \(reason)"
        }
    }
}

/// Wraps a value that is safe to hand across threads in practice (immutable
/// Core Graphics / Core Video objects) but isn't annotated `Sendable`.
nonisolated struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Recording time with pauses excluded, readable from any thread.
nonisolated final class ActiveClock: Sendable {
    private struct State {
        var base: Double
        var resumedAt: Double?
    }

    private let state: Mutex<State>

    init(startingAt base: Double = 0) {
        state = Mutex(State(base: base, resumedAt: nil))
    }

    private static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    var isRunning: Bool { state.withLock { $0.resumedAt != nil } }

    var seconds: Double {
        state.withLock { state in
            state.base + (state.resumedAt.map { Self.uptime - $0 } ?? 0)
        }
    }

    func resume() {
        state.withLock { state in
            if state.resumedAt == nil { state.resumedAt = Self.uptime }
        }
    }

    func pause() {
        state.withLock { state in
            if let resumedAt = state.resumedAt {
                state.base += Self.uptime - resumedAt
                state.resumedAt = nil
            }
        }
    }
}

/// The one serial queue that capture callbacks and the live video writer use,
/// so frames are appended in order and never race the final flush.
nonisolated enum CaptureQueue {
    static let queue = DispatchQueue(label: "app.tempus.capture", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

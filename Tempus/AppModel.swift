import Observation
import SwiftData
import SwiftUI

enum Route: Hashable {
    case newSession
    case record
    case detail(Session)
}

/// App-wide state: navigation, the one active recording, and deletion.
@Observable
final class AppModel {
    var path: [Route] = []
    private(set) var recording: RecordingController?
    var pendingDelete: Session?

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) {
        do {
            container = try ModelContainer(for: Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        } catch {
            fatalError("Could not open the Tempus library: \(error)")
        }
        recoverInterruptedSessions()
    }

    /// Sessions left recording or paused by a quit or crash become complete.
    /// Video files are fragmented MP4, so they play up to the last fragment.
    private func recoverInterruptedSessions() {
        let complete = SessionStatus.complete.rawValue
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.statusRaw != complete })
        guard let unfinished = try? context.fetch(descriptor), !unfinished.isEmpty else { return }
        for session in unfinished {
            session.status = .complete
            session.endedAt = session.endedAt ?? .now
            if session.mode == .video {
                session.videoBytes = SessionFiles.fileSize(SessionFiles.videoURL(for: session.id))
            }
        }
        try? context.save()
    }

    // MARK: Navigation

    func showNewSession() {
        if recording != nil { path = [.record] } else { path = [.newSession] }
    }

    func open(_ session: Session) {
        if recording?.session.id == session.id {
            path = [.record]
        } else {
            path = [.detail(session)]
        }
    }

    // MARK: Recording

    func startRecording(source: CaptureSource, mode: CaptureMode, intervalSeconds: Int, speed: Int) async throws {
        let session = Session(name: Session.defaultName(), mode: mode, sourceKind: source.kind,
                              sourceLabel: source.label, intervalSeconds: intervalSeconds, speed: speed)
        context.insert(session)
        let controller = RecordingController(session: session, source: source, context: context)
        do {
            try await controller.start()
        } catch {
            controller.cancel()
            context.delete(session)
            try? context.save()
            SessionFiles.delete(session.id)
            throw error
        }
        recording = controller
        path = [.record]
    }

    func finishRecording(name: String) async {
        guard let recording else { return }
        await recording.stop(name: name)
        self.recording = nil
        path = [.detail(recording.session)]
    }

    // MARK: Deletion

    func delete(_ session: Session) {
        if recording?.session.id == session.id {
            recording?.cancel()
            recording = nil
        }
        path = []
        SessionFiles.delete(session.id)
        context.delete(session)
        try? context.save()
    }
}

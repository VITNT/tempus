import AppKit
import CoreImage
import SwiftData
import SwiftUI
import Testing
@testable import Tempus

/// Renders each screen into a real window and saves PNGs for a visual check.
/// Opt-in: run with `TEST_RUNNER_TEMPUS_SNAPSHOTS=1 xcodebuild test …`.
/// Images land in the test host's temporary folder under `tempus-snapshots/`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEMPUS_SNAPSHOTS"] != nil))
struct SnapshotTests {
    static let folder = FileManager.default.temporaryDirectory.appending(path: "tempus-snapshots")

    private func seed(_ model: AppModel) throws -> [Session] {
        let specs: [(String, CaptureMode, SessionStatus, Double, (Double, Double, Double))] = [
            ("Portfolio redesign", .video, .complete, 2 * 3600 + 14 * 60, (0.15, 0.35, 0.8)),
            ("Rust capture spike", .screenshots, .complete, 47 * 60, (0.75, 0.3, 0.25)),
            ("Hackathon build", .video, .complete, 5 * 3600 + 3 * 60, (0.2, 0.6, 0.4)),
        ]
        var sessions: [Session] = []
        for (index, spec) in specs.enumerated() {
            let session = Session(name: spec.0, mode: spec.1, sourceKind: .display, sourceLabel: "Studio Display",
                                  intervalSeconds: 30, speed: 60)
            session.status = spec.2
            session.trackedSeconds = spec.3
            session.createdAt = .now.addingTimeInterval(Double(-index) * 86_400)
            session.frameCount = 94
            session.videoSeconds = spec.3 / 60
            session.videoBytes = Int64(spec.3 * 18_000)
            session.videoCodec = "hevc"
            session.videoWidth = 2560
            session.videoHeight = 1440
            try SessionFiles.prepare(for: session.id)
            let (r, g, b) = spec.4
            let image = CIImage(color: CIColor(red: r, green: g, blue: b))
                .cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1000))
            Stills.writeJPEG(Stills.thumbnail(of: image)!, to: SessionFiles.thumbnailURL(for: session.id))
            for frame in 1...3 {
                try Stills.writeHEIC(image, to: SessionFiles.frameURL(for: session.id, index: frame))
            }
            model.context.insert(session)
            sessions.append(session)
        }
        try model.context.save()
        return sessions
    }

    private func render<V: View>(_ name: String, size: CGSize = CGSize(width: 600, height: 720), @ViewBuilder _ view: () -> V) async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: 0), size: size),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: view().frame(width: size.width, height: size.height))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            // Let layout, tasks and async image loads settle.
            try await Task.sleep(for: .seconds(1.5))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let suffix = appearance == .aqua ? "light" : "dark"
            try rep.representation(using: .png, properties: [:])!.write(to: Self.folder.appending(path: "\(name)-\(suffix).png"))
            window.orderOut(nil)
        }
    }

    @Test func screens() async throws {
        let model = AppModel(inMemory: true)
        let sessions = try seed(model)
        defer { sessions.forEach { SessionFiles.delete($0.id) } }

        try await render("gallery") {
            NavigationStack { GalleryView() }.environment(model).modelContainer(model.container)
        }
        let emptyModel = AppModel(inMemory: true)
        try await render("gallery-empty") {
            NavigationStack { GalleryView() }.environment(emptyModel).modelContainer(emptyModel.container)
        }
        try await render("detail-video") {
            NavigationStack { DetailView(session: sessions[0]) }.environment(model).modelContainer(model.container)
        }
        try await render("detail-screenshots") {
            NavigationStack { DetailView(session: sessions[1]) }.environment(model).modelContainer(model.container)
        }
        let live = Session(name: "Timelapse Nov 19", mode: .video, sourceKind: .display, sourceLabel: "Studio Display",
                           intervalSeconds: 30, speed: 60)
        live.videoSeconds = 42
        live.videoBytes = 12_400_000
        model.context.insert(live)
        let controller = RecordingController(
            session: live,
            source: CaptureSource(target: .display(1), label: "Studio Display", pixelWidth: 5120, pixelHeight: 2880),
            context: model.context)
        try await render("record") {
            NavigationStack { RecordView(controller: controller) }.environment(model).modelContainer(model.container)
        }
        try await render("settings", size: CGSize(width: 460, height: 520)) {
            SettingsView()
        }
        print("Snapshots written to \(Self.folder.path())")
    }
}

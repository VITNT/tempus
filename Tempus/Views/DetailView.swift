import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct DetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if session.mode == .video {
                    VideoDetail(session: session)
                } else {
                    ScreenshotDetail(session: session)
                }
            }
            .padding(20)
        }
        .navigationTitle(session.name)
        .navigationSubtitle(session.createdAt.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Delete", systemImage: "trash", role: .destructive) { model.pendingDelete = session }
                    .help("Delete this timelapse")
            }
        }
    }
}

/// Asks where to save, defaulting to the session's name.
@MainActor
func chooseVideoDestination(for session: Session) -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.mpeg4Movie]
    panel.nameFieldStringValue = "\(Format.filename(session.name)).mp4"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    return panel.runModal() == .OK ? panel.url : nil
}

private struct VideoDetail: View {
    let session: Session
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var savedURL: URL?

    private var videoURL: URL { SessionFiles.videoURL(for: session.id) }
    private var hasVideo: Bool { FileManager.default.fileExists(atPath: videoURL.path(percentEncoded: false)) }

    var body: some View {
        MediaFrame(aspectRatio: session.aspectRatio) {
            if let player {
                VideoPlayer(player: player)
            } else {
                Text(hasVideo ? "Loading video…" : "No video was recorded").foregroundStyle(.secondary)
            }
        }
        .task(id: session.id) {
            if hasVideo { player = AVPlayer(url: videoURL) }
        }
        .onDisappear { player?.pause() }

        Grid(horizontalSpacing: 10) {
            GridRow {
                StatTile(value: Format.tracked(session.trackedSeconds), label: "Recorded")
                StatTile(value: "\(session.speed)×", label: "Speed")
                StatTile(value: Format.videoLength(session.videoSeconds), label: "Video length")
                StatTile(value: Format.bytes(max(session.videoBytes, SessionFiles.fileSize(videoURL))), label: formatLabel)
            }
        }

        if let errorMessage { ErrorBanner(message: errorMessage) }

        SaveButton(title: saving ? "Saving…" : "Save Video", busy: saving, savedURL: savedURL) {
            save()
        }
        .disabled(!hasVideo || saving)
    }

    private var formatLabel: String {
        guard session.videoWidth > 0 else { return "File size" }
        let codec = VideoCodec(rawValue: session.videoCodec ?? "")?.displayName ?? "H.264"
        return "\(session.videoWidth)×\(session.videoHeight) \(codec)"
    }

    private func save() {
        guard let destination = chooseVideoDestination(for: session) else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: videoURL, to: destination)
            savedURL = destination
        } catch {
            errorMessage = "Could not save the video: \(error.localizedDescription)"
        }
    }
}

private struct ScreenshotDetail: View {
    let session: Session
    @State private var frames: [URL] = []
    @State private var index = 0
    @State private var exporting = false
    @State private var progress = 0.0
    @State private var errorMessage: String?
    @State private var savedURL: URL?

    var body: some View {
        MediaFrame(aspectRatio: 16 / 10) {
            if frames.isEmpty {
                Text("No screenshots").foregroundStyle(.secondary)
            } else {
                DiskImage(url: frames[min(index, frames.count - 1)], contentMode: .fit)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(frames.isEmpty ? "No frames" : "\(index + 1) / \(frames.count)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .padding(10)
        }
        .task(id: session.id) {
            let id = session.id
            frames = await Task.detached { SessionFiles.frameURLs(for: id) }.value
            index = max(0, frames.count - 1)
        }

        if frames.count > 1 {
            Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                   in: 0...Double(frames.count - 1), step: 1) {
                Text("Frame")
            }
            .labelsHidden()
            .accessibilityValue("Frame \(index + 1) of \(frames.count)")
        }

        Grid(horizontalSpacing: 10) {
            GridRow {
                StatTile(value: Format.tracked(session.trackedSeconds), label: "Tracked time")
                StatTile(value: "\(session.frameCount)", label: "Screenshots")
                StatTile(value: Format.interval(session.intervalSeconds).replacingOccurrences(of: "Every ", with: ""), label: "Interval")
            }
        }

        if let errorMessage { ErrorBanner(message: errorMessage) }

        if exporting {
            ProgressView(value: progress) {
                Text("Rendering \(Int(progress * 100))%").font(.callout)
            }
        }

        SaveButton(title: exporting ? "Rendering…" : "Export Timelapse", busy: exporting, savedURL: savedURL) {
            Task { await export() }
        }
        .disabled(frames.isEmpty || exporting)
    }

    private func export() async {
        guard let destination = chooseVideoDestination(for: session) else { return }
        exporting = true
        progress = 0
        errorMessage = nil
        defer { exporting = false }
        let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        do {
            let frames = frames
            try await FrameExporter.export(frames: frames, to: temporary) { value in
                Task { @MainActor in progress = value }
            }
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
            savedURL = destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            errorMessage = error.localizedDescription
        }
    }
}

private struct SaveButton: View {
    let title: String
    let busy: Bool
    let savedURL: URL?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) } else { Image(systemName: "square.and.arrow.down") }
                    Text(title)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)

            if let savedURL, !busy {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                } label: {
                    Label("Saved to \(savedURL.lastPathComponent) — Show in Finder", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                }
                .buttonStyle(.link)
            }
        }
    }
}

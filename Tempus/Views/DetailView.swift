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

private struct VideoDetail: View {
    @Bindable var session: Session
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var progress = 0.0
    @State private var errorMessage: String?
    @State private var savedURL: URL?

    private var videoURL: URL { SessionFiles.videoURL(for: session.id) }
    private var hasVideo: Bool { FileManager.default.fileExists(atPath: videoURL.path(percentEncoded: false)) }

    var body: some View {
        MediaFrame(aspectRatio: session.aspectRatio) {
            if let player {
                PlayerView(player: player)
            } else {
                Text(hasVideo ? "Loading video…" : "No video was recorded").foregroundStyle(.secondary)
            }
        }
        .task(id: session.id) {
            if hasVideo {
                let player = AVPlayer(url: videoURL)
                self.player = player
                applyRate(to: player)
            }
        }
        .onChange(of: session.effectiveRate) {
            if let player { applyRate(to: player) }
        }
        .onDisappear { player?.pause() }

        VStack(alignment: .leading, spacing: 6) {
            Picker("Playback speed", selection: $session.effectiveRate) {
                ForEach(VideoPlan.playbackRates, id: \.self) { option in
                    Text(Format.rate(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!hasVideo || saving)
            Text(speedCaption).font(.caption).foregroundStyle(.secondary)
        }

        Grid(horizontalSpacing: 10) {
            GridRow {
                StatTile(value: Format.tracked(session.trackedSeconds), label: "Recorded")
                StatTile(value: Format.rate(session.effectiveRate), label: "Playback speed")
                StatTile(value: Format.videoLength(session.playbackVideoSeconds), label: "Video length")
                StatTile(value: Format.bytes(max(session.videoBytes, SessionFiles.fileSize(videoURL))), label: formatLabel)
            }
        }

        if let errorMessage { ErrorBanner(message: errorMessage) }

        if saving && isRetimed {
            ProgressView(value: progress) {
                Text("Rendering \(Int(progress * 100))%").font(.callout)
            }
        }

        SaveButton(title: saving ? (isRetimed ? "Rendering…" : "Saving…") : "Save Video", busy: saving, savedURL: savedURL) {
            Task { await save() }
        }
        .disabled(!hasVideo || saving)
    }

    private var isRetimed: Bool { session.effectiveRate != 1 }

    private var speedCaption: String {
        let rate = session.effectiveRate
        guard isRetimed else {
            return "1× is the original \(session.speed)× recording. Pick another speed to preview it; saving renders a new video at that speed."
        }
        let direction = rate > 1 ? "faster" : "slower"
        let note = rate < 1 ? " Frames are held on screen longer, so motion looks choppier." : ""
        return "\(Format.rate(rate)) \(direction) than recorded · \(Format.videoLength(session.playbackVideoSeconds)) video.\(note)"
    }

    /// Previews the chosen speed without re-encoding: the player just runs faster or slower.
    private func applyRate(to player: AVPlayer) {
        let rate = Float(session.effectiveRate)
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    private var formatLabel: String {
        guard session.videoWidth > 0 else { return "File size" }
        let codec = VideoCodec(rawValue: session.videoCodec ?? "")?.displayName ?? "H.264"
        return "\(session.videoWidth)×\(session.videoHeight) \(codec)"
    }

    private func save() async {
        guard let destination = ExportDestination.choose(for: session) else { return }
        saving = true
        progress = 0
        errorMessage = nil
        defer { saving = false }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        do {
            if isRetimed {
                try await VideoRetimer.export(from: videoURL, to: temporary, rate: session.effectiveRate) { value in
                    Task { @MainActor in progress = value }
                }
            } else {
                try manager.copyItem(at: videoURL, to: temporary)
            }
            savedURL = try destination.place(temporary)
        } catch {
            try? manager.removeItem(at: temporary)
            errorMessage = "Could not save the video: \(error.localizedDescription)"
        }
    }
}

private struct ScreenshotDetail: View {
    @Bindable var session: Session
    @State private var frames: [URL] = []
    @State private var index = 0
    @State private var playing = false
    @State private var exporting = false
    @State private var progress = 0.0
    @State private var errorMessage: String?
    @State private var savedURL: URL?
    /// Last frame whose checkbox was clicked, so Shift-click can toggle a whole range.
    @State private var anchor: Int?

    private var excluded: Set<String> { session.excludedFrames }
    private var selectedFrames: [URL] { SessionFiles.selectedFrames(frames, excluding: excluded) }

    private func isIncluded(_ i: Int) -> Bool { !excluded.contains(frames[i].lastPathComponent) }

    var body: some View {
        MediaFrame(aspectRatio: 16 / 10) {
            if frames.isEmpty {
                Text("No screenshots").foregroundStyle(.secondary)
            } else {
                DiskImage(url: frames[min(index, frames.count - 1)], contentMode: .fit)
                    .opacity(isIncluded(min(index, frames.count - 1)) ? 1 : 0.4)
            }
        }
        .overlay(alignment: .topLeading) {
            if !frames.isEmpty, !isIncluded(min(index, frames.count - 1)) {
                Label("Not in export", systemImage: "eye.slash")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .padding(10)
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

        .task(id: playing) {
            // Plays only the frames that will be exported, so the preview matches the video.
            guard playing, frames.count > 1 else { return }
            let playable = frames.indices.filter(isIncluded)
            guard let first = playable.first else { playing = false; return }
            if !playable.contains(where: { $0 > index }) || !isIncluded(index) {
                index = playable.first(where: { $0 > index }) ?? first
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0 / Double(session.effectiveFPS)))
                guard !Task.isCancelled else { return }
                guard let next = frames.indices.first(where: { $0 > index && isIncluded($0) }) else { playing = false; return }
                index = next
            }
        }

        if frames.count > 1 {
            HStack(spacing: 12) {
                Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                    playing.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .keyboardShortcut(.space, modifiers: [])
                .help(playing ? "Pause preview" : "Play preview at \(session.effectiveFPS) fps")

                Slider(value: Binding(get: { Double(index) }, set: { playing = false; index = Int($0.rounded()) }),
                       in: 0...Double(frames.count - 1), step: 1) {
                    Text("Frame")
                }
                .labelsHidden()
                .accessibilityValue("Frame \(index + 1) of \(frames.count)")
            }
        }

        if !frames.isEmpty {
            frameSelection
        }

        VStack(alignment: .leading, spacing: 6) {
            Picker("Frames per second", selection: $session.effectiveFPS) {
                ForEach(FrameExporter.fpsOptions, id: \.self) { option in
                    Text("\(option) fps").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(exporting)
            Text("How fast the screenshots play, in the preview and the exported video.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Grid(horizontalSpacing: 10) {
            GridRow {
                StatTile(value: Format.tracked(session.trackedSeconds), label: "Tracked time")
                StatTile(value: "\(session.frameCount)", label: "Screenshots")
                StatTile(value: Format.interval(session.intervalSeconds).replacingOccurrences(of: "Every ", with: ""), label: "Interval")
                StatTile(value: Format.videoLength(Double(selectedFrames.count) / Double(session.effectiveFPS)), label: "Video length")
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
        .disabled(selectedFrames.isEmpty || exporting)
    }

    private var frameSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Frames in export").font(.headline)
                Text("\(selectedFrames.count) of \(frames.count)")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Toggle("Include this frame", isOn: Binding(
                    get: { isIncluded(min(index, frames.count - 1)) },
                    set: { _ in toggle(min(index, frames.count - 1), extend: false) }))
                    .toggleStyle(.checkbox)
                    .keyboardShortcut("e", modifiers: [])
                    .help("Include or leave out the frame shown above (E)")
                Menu("Select") {
                    Button("Include All Frames") { setIncluded(frames.indices, true) }
                    Button("Exclude All Frames") { setIncluded(frames.indices, false) }
                    Divider()
                    Button("Exclude Frames Before This One") { setIncluded(0..<index, false) }
                    Button("Exclude Frames After This One") { setIncluded((index + 1)..<frames.count, false) }
                    Button("Invert Selection") {
                        session.excludedFrames = Set(frames.indices.filter(isIncluded).map { frames[$0].lastPathComponent })
                    }
                }
                .fixedSize()
            }
            .disabled(exporting)

            FrameStrip(frames: frames, excluded: excluded, index: $index, onToggle: toggle)
                .disabled(exporting)

            Text("Click a thumbnail to preview it; use its checkbox to include or leave it out. Shift-click a checkbox to change a range.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Flips one frame, or with `extend` sets every frame from the last-clicked one to `i` to `i`'s new state.
    private func toggle(_ i: Int, extend: Bool) {
        playing = false
        let include = !isIncluded(i)
        if extend, let anchor, anchor < frames.count {
            setIncluded(min(anchor, i)...max(anchor, i), include)
        } else {
            setIncluded(i...i, include)
        }
        anchor = i
    }

    private func setIncluded<R: Sequence<Int>>(_ indices: R, _ include: Bool) {
        var excluded = session.excludedFrames
        for i in indices where frames.indices.contains(i) {
            let name = frames[i].lastPathComponent
            if include { excluded.remove(name) } else { excluded.insert(name) }
        }
        session.excludedFrames = excluded
    }

    private func export() async {
        guard let destination = ExportDestination.choose(for: session) else { return }
        playing = false
        exporting = true
        progress = 0
        errorMessage = nil
        defer { exporting = false }
        let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        do {
            let frames = selectedFrames
            try await FrameExporter.export(frames: frames, fps: session.effectiveFPS, to: temporary) { value in
                Task { @MainActor in progress = value }
            }
            savedURL = try destination.place(temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            errorMessage = error.localizedDescription
        }
    }
}

/// Horizontal strip of frame thumbnails with an include checkbox on each.
private struct FrameStrip: View {
    let frames: [URL]
    let excluded: Set<String>
    @Binding var index: Int
    let onToggle: (_ index: Int, _ extend: Bool) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(frames.indices, id: \.self) { i in
                        thumbnail(i)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(height: 84)
            .onChange(of: index) { proxy.scrollTo(index, anchor: .center) }
            .onAppear { proxy.scrollTo(index, anchor: .center) }
        }
    }

    private func thumbnail(_ i: Int) -> some View {
        let included = !excluded.contains(frames[i].lastPathComponent)
        return DiskImage(url: frames[i], contentMode: .fill, maxPixelSize: 240)
            .frame(width: 112, height: 70)
            .background(.black.opacity(0.85))
            .clipShape(.rect(cornerRadius: 8))
            .opacity(included ? 1 : 0.35)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(i == index ? Color.accentColor : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topLeading) {
                Button {
                    onToggle(i, NSEvent.modifierFlags.contains(.shift))
                } label: {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, included ? Color.accentColor : .black.opacity(0.4))
                        .shadow(radius: 1)
                }
                .buttonStyle(.plain)
                .padding(4)
                .help(included ? "Leave this frame out of the export" : "Include this frame in the export")
                .accessibilityLabel(included ? "Exclude frame \(i + 1)" : "Include frame \(i + 1)")
            }
            .contentShape(.rect)
            .onTapGesture { index = i }
            .id(i)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Frame \(i + 1)\(included ? "" : ", not in export")")
    }
}

private struct SaveButton: View {
    let title: String
    let busy: Bool
    let savedURL: URL?
    let action: () -> Void
    @AppStorage(Preferences.exportFolder) private var folderBookmark: Data?

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

            HStack(spacing: 6) {
                if let folder = ExportFolder.resolve(folderBookmark) {
                    Label("Saves to “\(folder.lastPathComponent)”", systemImage: "folder")
                } else {
                    Label("Asks where to save each time", systemImage: "folder")
                }
                Button("Change…") {
                    if let bookmark = ExportFolder.choose() { folderBookmark = bookmark }
                }
                .buttonStyle(.link)
                .disabled(busy)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// AppKit-backed player. SwiftUI's `VideoPlayer` lives in `_AVKit_SwiftUI`, which the
/// linker can pull in without AVKit itself; its class metadata then fails to find its
/// AVKit superclass at runtime and the app aborts. Referencing `AVPlayerView` directly
/// links AVKit and avoids the overlay entirely.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

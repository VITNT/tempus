import SwiftUI

struct NewSessionView: View {
    private enum SourceTab: String, CaseIterable, Identifiable {
        case screen, camera
        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.mode) private var mode: CaptureMode = .screenshots
    @AppStorage(Preferences.speed) private var speed = VideoPlan.defaultSpeed
    @AppStorage(Preferences.interval) private var interval = Preferences.defaultInterval

    @State private var tab: SourceTab = .screen
    @State private var screens: [CaptureSource] = []
    @State private var cameras: [CaptureSource] = []
    @State private var selectedID: CaptureSource.ID?
    @State private var loading = true
    @State private var starting = false
    @State private var errorMessage: String?
    @State private var needsPermission = false

    private var visibleSources: [CaptureSource] { tab == .screen ? screens : cameras }
    private var selected: CaptureSource? { visibleSources.first { $0.id == selectedID } }

    var body: some View {
        Form {
            Section {
                Picker("Recording mode", selection: $mode) {
                    Label("Screenshots", systemImage: "photo.on.rectangle").tag(CaptureMode.screenshots)
                    Label("Video", systemImage: "film").tag(CaptureMode.video)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(mode == .video
                     ? "Records a sped-up HEVC video as you work. Nothing is stored but the video."
                     : "Saves a full-resolution screenshot every \(interval) seconds. Export a video whenever you like.")
            }

            Section {
                Picker("Source", selection: $tab) {
                    Label("Screens & Windows", systemImage: "macwindow.on.rectangle").tag(SourceTab.screen)
                    Label("Cameras", systemImage: "web.camera").tag(SourceTab.camera)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if loading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(tab == .screen ? "Finding screens and windows…" : "Finding cameras…").foregroundStyle(.secondary)
                    }
                } else if needsPermission {
                    PermissionPrompt(kind: tab == .screen ? .display : .camera) { Task { await load() } }
                } else if visibleSources.isEmpty {
                    Text(tab == .screen ? "No screens or windows are available." : "No cameras are connected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleSources) { source in
                        SourceRow(source: source, isSelected: source.id == selectedID) { selectedID = source.id }
                    }
                }
            } header: {
                Text("What should Tempus capture?")
            }

            if mode == .video {
                Section {
                    SpeedPicker(speed: $speed)
                } header: {
                    Text("Playback speed")
                } footer: {
                    Text("Records a \(speed)× video (\(Format.speedSummary(speed))) · up to ~\(Int(estimateMB.rounded())) MB per hour")
                }
            }

            if let errorMessage {
                Section { ErrorBanner(message: errorMessage) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Timelapse")
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await start() }
            } label: {
                HStack(spacing: 8) {
                    if starting { ProgressView().controlSize(.small) }
                    Text(starting ? "Starting…" : "Start Recording")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .disabled(selected == nil || starting)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .help("Refresh the list of sources")
                    .disabled(loading)
            }
        }
        .task(id: tab) { await load() }
    }

    private var estimateMB: Double {
        let size = selected.map { ($0.pixelWidth, $0.pixelHeight) } ?? (tab == .screen ? (3840, 2160) : (1920, 1080))
        let bitrate = VideoPlan.bitrate(codec: .hevc, width: max(2, size.0), height: max(2, size.1), speed: speed).bitrate
        return VideoPlan.estimatedMegabytesPerHour(bitrate: bitrate, speed: speed)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        needsPermission = false
        defer { loading = false }
        switch tab {
        case .screen:
            if !SourceCatalog.hasScreenAccess {
                SourceCatalog.requestScreenAccess()
                guard SourceCatalog.hasScreenAccess else { needsPermission = true; return }
            }
            do {
                screens = try await SourceCatalog.screenSources()
            } catch {
                needsPermission = !SourceCatalog.hasScreenAccess
                if !needsPermission { errorMessage = error.localizedDescription }
            }
        case .camera:
            guard await SourceCatalog.cameraAccess() else { needsPermission = true; return }
            cameras = SourceCatalog.cameras()
        }
        if selected == nil { selectedID = visibleSources.first?.id }
    }

    private func start() async {
        guard let source = selected else { return }
        starting = true
        errorMessage = nil
        defer { starting = false }
        do {
            try await model.startRecording(source: source, mode: mode, intervalSeconds: interval, speed: speed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SourceRow: View {
    let source: CaptureSource
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: source.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.label).lineLimit(1)
                    Text(source.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SpeedPicker: View {
    @Binding var speed: Int
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(VideoPlan.speedOptions, id: \.self) { option in
                    let isSelected = option == speed
                    Button {
                        withAnimation(.snappy) { speed = option }
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(option)×").font(.headline).monospacedDigit()
                            Text(Format.speedOutput(option)).font(.caption2).foregroundStyle(isSelected ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(isSelected ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(),
                                 in: .rect(cornerRadius: 12))
                    .glassEffectID(option, in: glass)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }
}

private struct PermissionPrompt: View {
    let kind: SourceKind
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(kind == .camera ? "Camera access is off" : "Screen Recording access is off",
                  systemImage: "lock.shield")
                .font(.headline)
            Text(kind == .camera
                 ? "Allow Tempus to use the camera in System Settings › Privacy & Security › Camera."
                 : "Allow Tempus in System Settings › Privacy & Security › Screen & System Audio Recording. You may need to quit and reopen Tempus afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open System Settings") { SourceCatalog.openPrivacySettings(for: kind) }
                    .buttonStyle(.glassProminent)
                Button("Try Again", action: retry)
                    .buttonStyle(.glass)
            }
        }
        .padding(.vertical, 4)
    }
}

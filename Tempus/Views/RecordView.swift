import SwiftUI

struct RecordView: View {
    @Environment(AppModel.self) private var model
    let controller: RecordingController
    @State private var naming = false
    @State private var name = ""

    private var session: Session { controller.session }
    private var isVideo: Bool { session.mode == .video }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                preview
                statusCard
                sourceLine
                if let message = controller.errorMessage {
                    ErrorBanner(message: message)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) { controls }
        .navigationTitle(session.name)
        .navigationSubtitle(isVideo ? "Video · \(session.speed)× speed" : Format.interval(session.intervalSeconds))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Gallery", systemImage: "square.grid.2x2") { model.path = [] }
                    .help("Back to the gallery — recording continues")
            }
        }
        .sheet(isPresented: $naming) {
            NameSheet(name: $name, isBusy: controller.isBusy) {
                Task { await model.finishRecording(name: name) }
            } cancel: {
                naming = false
            }
        }
    }

    private var preview: some View {
        MediaFrame(aspectRatio: session.aspectRatio) {
            if let image = controller.preview {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing your first capture…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(controller.preview == nil ? "Live preview" : isVideo ? "Recording video" : "Latest capture")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            Label("Local", systemImage: "lock.fill")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .padding(10)
                .help("Frames never leave this Mac")
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: controller.isRecording ? "record.circle.fill" : "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(controller.isRecording ? .red : .orange)
                .symbolEffect(.pulse, isActive: controller.isRecording)
                .contentTransition(.symbolEffect(.replace))
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(Format.clock(controller.clock.seconds))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            Text(stats)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private var stats: String {
        if isVideo {
            return "\(Format.runningVideoLength(session.videoSeconds)) video · \(Format.bytes(session.videoBytes))"
        }
        return session.frameCount == 1 ? "1 screenshot" : "\(session.frameCount) screenshots"
    }

    private var sourceLine: some View {
        Label(session.sourceLabel, systemImage: controller.source.systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if controller.isRecording {
                    Button {
                        Task { await controller.pause() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else {
                    Button {
                        Task { await controller.resume() }
                    } label: {
                        Label(controller.isBusy ? "Reconnecting…" : "Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(controller.isBusy)
                }
                Button {
                    name = session.name
                    naming = true
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
            }
            .controlSize(.extraLarge)
        }
        .keyboardShortcut(.space, modifiers: [])
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

private struct NameSheet: View {
    @Binding var name: String
    let isBusy: Bool
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name your timelapse").font(.title3.weight(.semibold))
            Text("Give it a name, or keep the default.").foregroundStyle(.secondary)
            TextField("My timelapse", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .disabled(isBusy)
            HStack {
                Spacer()
                Button("Keep Recording", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button(action: save) {
                    HStack(spacing: 6) {
                        if isBusy { ProgressView().controlSize(.small) }
                        Text(isBusy ? "Saving…" : "Save & Stop")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

import SwiftData
import SwiftUI

struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 16)]

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Timelapses Yet", systemImage: "display")
                } description: {
                    Text("Start a recording session to see it here.")
                } actions: {
                    Button("New Timelapse", systemImage: "plus") { model.showNewSession() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(sessions) { session in
                            SessionCard(session: session)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Your Timelapses")
        .safeAreaInset(edge: .bottom) {
            if let recording = model.recording {
                RecordingPill(controller: recording)
                    .padding(.bottom, 16)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Timelapse", systemImage: "plus") { model.showNewSession() }
                    .help("Start a timelapse (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
    }
}

/// Floating glass pill that leads back to the recorder.
private struct RecordingPill: View {
    @Environment(AppModel.self) private var model
    let controller: RecordingController

    var body: some View {
        Button {
            model.path = [.record]
        } label: {
            HStack(spacing: 10) {
                Image(systemName: controller.isRecording ? "record.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(controller.isRecording ? .red : .orange)
                    .symbolEffect(.pulse, isActive: controller.isRecording)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Format.clock(controller.clock.seconds)).monospacedDigit()
                }
                Text(controller.session.name).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

struct SessionCard: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var hovering = false

    var body: some View {
        Button { model.open(session) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    Image(systemName: session.sourceKind == .camera ? "web.camera" : "display")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    DiskImage(url: SessionFiles.thumbnailURL(for: session.id), version: session.thumbnailVersion)
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 14))
                .overlay(alignment: .topLeading) {
                    StatusBadge(status: session.status).padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button {
                            model.pendingDelete = session
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .help("Delete timelapse")
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 12 : 6, y: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { model.open(session) }
            Divider()
            Button("Delete…", role: .destructive) { model.pendingDelete = session }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the timelapse")
    }

    private var subtitle: String {
        var parts = [Format.tracked(session.trackedSeconds)]
        if session.mode == .video { parts.append("\(session.speed)× video") }
        parts.append(session.createdAt.formatted(.dateTime.month(.abbreviated).day()))
        return parts.joined(separator: " · ")
    }
}

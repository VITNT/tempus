import SwiftUI

/// Loads a JPEG/HEIC from disk off the main thread. Changing `version`
/// reloads it (the recorder rewrites the same thumbnail file).
struct DiskImage: View {
    let url: URL
    var version = 0
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .task(id: "\(url.path())#\(version)") {
            let url = url
            image = await Task.detached(priority: .utility) { Stills.loadImage(at: url).map(Unchecked.init) }.value?.value
        }
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }

    private var title: String {
        switch status {
        case .recording: "Recording"
        case .paused: "Paused"
        case .complete: "Complete"
        }
    }

    private var symbol: String {
        switch status {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .complete: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .recording: .red
        case .paused: .orange
        case .complete: .green
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.primary)
            .symbolRenderingMode(.multicolor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.red.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

/// Rounded media frame used by the recorder and detail screens.
struct MediaFrame<Content: View>: View {
    var aspectRatio: CGFloat = 16 / 10
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85))
            content
        }
        // The frame is always dark, so placeholder text and spinners must be too.
        .environment(\.colorScheme, .dark)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }
}

extension Session {
    var aspectRatio: CGFloat {
        videoWidth > 0 && videoHeight > 0 ? CGFloat(videoWidth) / CGFloat(videoHeight) : 16 / 10
    }
}

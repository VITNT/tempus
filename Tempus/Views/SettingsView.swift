import SwiftUI

struct SettingsView: View {
    @AppStorage(Preferences.interval) private var interval = Preferences.defaultInterval

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                Picker("Capture frequency", selection: $interval) {
                    ForEach(Preferences.intervalOptions, id: \.self) { seconds in
                        Text(Format.interval(seconds)).tag(seconds)
                    }
                }
            } footer: {
                Text("How often Tempus saves a screenshot while recording in Screenshots mode.")
            }

            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local-only by design").font(.headline)
                        Text("Frames and videos stay in Tempus’s folder on this Mac. Tempus has no server, account, analytics, or upload endpoint.")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                }
                Button("Show Recordings in Finder") {
                    try? FileManager.default.createDirectory(at: SessionFiles.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SessionFiles.root)
                }
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent("Version", value: version)
                Text("Standalone screen and camera timelapses, inspired by Hack Club Lookout. Unlike Lookout, Tempus creates and owns its sessions directly.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("About Tempus")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

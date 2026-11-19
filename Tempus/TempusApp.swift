import SwiftUI
import SwiftData

@main
struct TempusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Tempus", id: "main") {
            ContentView()
                .environment(model)
                .modelContainer(model.container)
        }
        .defaultSize(width: 600, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Timelapse") { model.showNewSession() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            GalleryView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .newSession:
                        NewSessionView()
                    case .record:
                        if let recording = model.recording {
                            RecordView(controller: recording)
                        } else {
                            ContentUnavailableView("Nothing Recording", systemImage: "record.circle")
                        }
                    case .detail(let session):
                        DetailView(session: session)
                    }
                }
        }
        .frame(minWidth: 480, minHeight: 600)
        .confirmationDialog(
            "Delete timelapse?",
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            presenting: model.pendingDelete
        ) { session in
            Button("Delete", role: .destructive) { model.delete(session) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            let contents = session.mode == .video ? "recorded video" : "\(session.frameCount) local screenshots"
            Text("This permanently removes “\(session.name)” and its \(contents).")
        }
    }
}

import AppKit
import Foundation
import UniformTypeIdentifiers

/// The folder exports save into, chosen in Settings. Stored as a security-scoped
/// bookmark so the sandboxed app can keep writing there after a relaunch.
/// With no folder chosen, every export asks where to save.
enum ExportFolder {
    /// The folder, or nil when none is chosen or it no longer exists.
    static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = makeBookmark(for: url) {
            UserDefaults.standard.set(fresh, forKey: Preferences.exportFolder)
        }
        return url
    }

    static var current: URL? { resolve(UserDefaults.standard.data(forKey: Preferences.exportFolder)) }

    /// Shows a folder picker; returns the new bookmark, or nil if cancelled.
    static func choose(startingAt folder: URL? = current) -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where Tempus saves exported videos."
        panel.directoryURL = folder ?? URL.moviesDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return makeBookmark(for: url)
    }

    private static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// `name.ext` in `folder`, or `name 2.ext`, `name 3.ext`… if that is taken.
    nonisolated static func uniqueURL(in folder: URL, name: String, ext: String,
                                      exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) -> URL {
        var candidate = folder.appending(path: "\(name).\(ext)")
        var number = 2
        while exists(candidate) {
            candidate = folder.appending(path: "\(name) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

/// Where one export will be saved: a file picked in the save panel, or the export folder.
struct ExportDestination {
    private enum Target {
        case file(URL)
        case folder(URL, name: String)
    }

    private let target: Target

    /// Uses the export folder when one is set; otherwise asks with a save panel.
    static func choose(for session: Session) -> ExportDestination? {
        let name = Format.filename(session.name)
        if let folder = ExportFolder.current {
            return ExportDestination(target: .folder(folder, name: name))
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(name).mp4"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url.map { ExportDestination(target: .file($0)) } : nil
    }

    /// Moves the finished `file` into place and returns where it ended up.
    func place(_ file: URL) throws -> URL {
        let manager = FileManager.default
        switch target {
        case .file(let url):
            // The user confirmed replacing it in the save panel.
            if manager.fileExists(atPath: url.path(percentEncoded: false)) {
                try manager.removeItem(at: url)
            }
            try manager.moveItem(at: file, to: url)
            return url
        case .folder(let folder, let name):
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            guard manager.fileExists(atPath: folder.path(percentEncoded: false)) else {
                throw TempusError.exportFailed("The export folder “\(folder.lastPathComponent)” is missing. Choose another in Settings.")
            }
            let url = ExportFolder.uniqueURL(in: folder, name: name, ext: "mp4")
            try manager.moveItem(at: file, to: url)
            return url
        }
    }
}

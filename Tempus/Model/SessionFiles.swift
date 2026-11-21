import Foundation

/// On-disk layout for a session:
///
///     Application Support/Tempus/Sessions/<id>/
///         thumbnail.jpg
///         timelapse.mp4        (video mode)
///         frames/000001.heic   (screenshot mode)
nonisolated enum SessionFiles {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Tempus/Sessions", directoryHint: .isDirectory)
    }

    static func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func framesFolder(for id: UUID) -> URL {
        folder(for: id).appending(path: "frames", directoryHint: .isDirectory)
    }

    static func videoURL(for id: UUID) -> URL {
        folder(for: id).appending(path: "timelapse.mp4")
    }

    static func thumbnailURL(for id: UUID) -> URL {
        folder(for: id).appending(path: "thumbnail.jpg")
    }

    static func frameURL(for id: UUID, index: Int) -> URL {
        framesFolder(for: id).appending(path: String(format: "%06d.heic", index))
    }

    static func prepare(for id: UUID) throws {
        try FileManager.default.createDirectory(at: framesFolder(for: id), withIntermediateDirectories: true)
    }

    /// Frame files in capture order (zero-padded names sort correctly).
    static func frameURLs(for id: UUID) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: framesFolder(for: id), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "heic" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The frames an export uses: `frames` in order, minus any whose file name is excluded.
    static func selectedFrames(_ frames: [URL], excluding excluded: Set<String>) -> [URL] {
        excluded.isEmpty ? frames : frames.filter { !excluded.contains($0.lastPathComponent) }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }
}

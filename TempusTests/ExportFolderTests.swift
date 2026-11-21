import Foundation
import Testing
@testable import Tempus

struct ExportFolderTests {
    private let folder = URL(filePath: "/tmp/exports", directoryHint: .isDirectory)

    @Test func freeNameIsUsedAsIs() {
        let url = ExportFolder.uniqueURL(in: folder, name: "Timelapse Nov 20", ext: "mp4") { _ in false }
        #expect(url.lastPathComponent == "Timelapse Nov 20.mp4")
    }

    @Test func takenNamesGetANumber() {
        let taken: Set<String> = ["Timelapse.mp4", "Timelapse 2.mp4"]
        let url = ExportFolder.uniqueURL(in: folder, name: "Timelapse", ext: "mp4") { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Timelapse 3.mp4")
        #expect(url.deletingLastPathComponent().lastPathComponent == "exports")
    }
}

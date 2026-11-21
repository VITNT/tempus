import Foundation
import Testing
@testable import Tempus

struct FrameSelectionTests {
    private let frames = (1...5).map { URL(filePath: "/tmp/frames/\(String(format: "%06d", $0)).heic") }

    @Test func noExclusionsKeepsEveryFrame() {
        #expect(SessionFiles.selectedFrames(frames, excluding: []) == frames)
    }

    @Test func excludedFramesAreSkippedInOrder() {
        let selected = SessionFiles.selectedFrames(frames, excluding: ["000002.heic", "000004.heic", "999999.heic"])
        #expect(selected.map(\.lastPathComponent) == ["000001.heic", "000003.heic", "000005.heic"])
    }

    @Test func emptyExclusionSetIsStoredAsNil() {
        let session = Session(name: "Test", mode: .screenshots, sourceKind: .display, sourceLabel: "Display",
                              intervalSeconds: 5, speed: 60)
        session.excludedFrames = ["000003.heic", "000001.heic"]
        #expect(session.excludedFrameNames == ["000001.heic", "000003.heic"])
        session.excludedFrames = []
        #expect(session.excludedFrameNames == nil)
    }
}

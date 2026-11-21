import Testing
@testable import Tempus

struct FormattingTests {
    @Test func clock() {
        #expect(Format.clock(0) == "00:00:00")
        #expect(Format.clock(3723.9) == "01:02:03")
    }

    @Test func tracked() {
        #expect(Format.tracked(0.2) == "1 sec")
        #expect(Format.tracked(45) == "45 sec")
        #expect(Format.tracked(12 * 60 + 5) == "12 min")
        #expect(Format.tracked(2 * 3600 + 5 * 60) == "2h 5m")
    }

    @Test func videoLength() {
        #expect(Format.videoLength(42.4) == "42 sec")
        #expect(Format.videoLength(125) == "2:05")
        #expect(Format.runningVideoLength(5) == "0:05")
    }

    @Test func bytes() {
        #expect(Format.bytes(400) == "1 KB")
        #expect(Format.bytes(250_000) == "250 KB")
        #expect(Format.bytes(4_200_000) == "4.2 MB")
        #expect(Format.bytes(42_000_000) == "42 MB")
        #expect(Format.bytes(1_500_000_000) == "1.50 GB")
    }

    @Test func rate() {
        #expect(Format.rate(1) == "1×")
        #expect(Format.rate(0.25) == "0.25×")
        #expect(Format.rate(1.5) == "1.5×")
    }

    @Test func speedOutput() {
        #expect(Format.speedOutput(2) == "30 min")
        #expect(Format.speedOutput(5) == "12 min")
        #expect(Format.speedOutput(60) == "1 min")
        #expect(Format.speedOutput(120) == "30 sec")
        #expect(Format.speedOutput(300) == "12 sec")
        #expect(Format.speedSummary(60) == "1 hr → 1 min")
    }

    @Test func interval() {
        #expect(Format.interval(5) == "Every 5 seconds")
        #expect(Format.interval(60) == "Every minute")
        #expect(Format.interval(120) == "Every 2 minutes")
    }

    @Test func filename() {
        #expect(Format.filename("  My Cool  Timelapse! ") == "my-cool-timelapse")
        #expect(Format.filename("Résumé_v2") == "résumé_v2")
        #expect(Format.filename("!!!") == "timelapse")
    }
}

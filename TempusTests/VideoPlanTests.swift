import Testing
@testable import Tempus

struct VideoPlanTests {
    @Test func bitrateUsesQualityTargetWhenUnderBudget() {
        // 1080p at 60×: quality = 1920·1080·30·0.045 ≈ 2.8 Mbps; budget ≈ 56.7 Mbps.
        let result = VideoPlan.bitrate(codec: .hevc, width: 1920, height: 1080, speed: 60)
        #expect(result.bitrate == 2_799_360)
        #expect(!result.budgetLimited)
    }

    @Test func bitrateIsCappedByHourlyBudget() {
        // 5K at 5×: quality ≈ 19.9 Mbps, budget = 500 MB·8·0.85 / 720 s ≈ 4.72 Mbps.
        let result = VideoPlan.bitrate(codec: .hevc, width: 5120, height: 2880, speed: 5)
        #expect(result.budgetLimited)
        #expect(result.bitrate == 4_722_222)
        let megabytes = VideoPlan.estimatedMegabytesPerHour(bitrate: result.bitrate, speed: 5)
        #expect(megabytes <= 500 * VideoPlan.budgetHeadroom + 0.01)
    }

    @Test func bitrateNeverDropsBelowFloor() {
        #expect(VideoPlan.bitrate(codec: .hevc, width: 320, height: 200, speed: 300).bitrate == VideoPlan.minBitrate)
    }

    @Test func h264NeedsMoreBitsThanHEVC() {
        let hevc = VideoPlan.bitrate(codec: .hevc, width: 2560, height: 1440, speed: 60).bitrate
        let h264 = VideoPlan.bitrate(codec: .h264, width: 2560, height: 1440, speed: 60).bitrate
        #expect(h264 > hevc)
    }

    @Test func candidateSizesStepDownAndStayEven() {
        let sizes = VideoPlan.candidateSizes(width: 5121, height: 2881)
        #expect(sizes.map(\.width) == [5120, 3838, 2560, 1920])
        #expect(sizes.allSatisfy { $0.width % 2 == 0 && $0.height % 2 == 0 })
    }

    @Test func candidateSizesRotateCapsForPortrait() {
        let sizes = VideoPlan.candidateSizes(width: 2160, height: 3840)
        #expect(sizes.first! == (2160, 3840))
        #expect(sizes.contains { $0 == (1080, 1920) })
    }

    @Test func smallSourcesAreNotDuplicated() {
        #expect(VideoPlan.candidateSizes(width: 1280, height: 800).count == 1)
    }

    @Test func candidatesPreferHEVCAtEachSize() {
        let plans = VideoPlan.candidates(width: 1920, height: 1080, speed: 60)
        #expect(plans.map(\.codec) == [.hevc, .h264])
    }

    @Test func frameIntervalMatchesSpeed() {
        #expect(VideoPlan.frameInterval(speed: 60) == 2)
        #expect(VideoPlan.videoSecondsPerHour(speed: 60) == 60)
    }
}

struct SlotSchedulerTests {
    @Test func oneHourAtSixtyTimesIsOneMinute() {
        var scheduler = SlotScheduler(speed: 60)
        var written = 0
        // A frame every 2 seconds of real time for an hour.
        for second in stride(from: 0.0, to: 3600, by: 2) where scheduler.claim(at: second) != nil {
            written += 1
        }
        #expect(written == 1800)
        #expect(scheduler.videoSeconds(at: 3600) == 60)
    }

    @Test func framesInAFilledSlotAreDropped() {
        var scheduler = SlotScheduler(speed: 60)
        #expect(scheduler.claim(at: 0) == 0)
        #expect(scheduler.claim(at: 1.9) == nil)
        #expect(scheduler.claim(at: 2.0) == 1)
    }

    @Test func gapsHoldThePreviousFrame() {
        var scheduler = SlotScheduler(speed: 60)
        _ = scheduler.claim(at: 0)
        // Static screen for 10 minutes: next frame lands 300 slots later.
        #expect(scheduler.claim(at: 600) == 300)
        #expect(scheduler.videoSeconds(at: 600) == 301.0 / 30)
    }

    @Test func staticEndingExtendsToStopTime() {
        var scheduler = SlotScheduler(speed: 30)
        _ = scheduler.claim(at: 0)
        // Last frame at 0 s, stopped at 60 s: video still covers the full minute (2 s).
        #expect(scheduler.endSlot(at: 60) == 60)
        #expect(scheduler.videoSeconds(at: 60) == 2)
    }

    @Test func videoStartsAtFirstFrame() {
        var scheduler = SlotScheduler(speed: 60)
        _ = scheduler.claim(at: 10)
        _ = scheduler.claim(at: 12)
        #expect(scheduler.firstSlot == 5)
        #expect(scheduler.videoSeconds(at: 12) == 2.0 / 30)
    }

    @Test func noFramesMeansNoVideo() {
        let scheduler = SlotScheduler(speed: 60)
        #expect(scheduler.endSlot(at: 100) == nil)
        #expect(scheduler.videoSeconds(at: 100) == 0)
    }
}

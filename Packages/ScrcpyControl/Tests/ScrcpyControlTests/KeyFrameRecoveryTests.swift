import Testing
@testable import ScrcpyControl

struct KeyFrameRecoveryTests {
    private final class Clock {
        var now = ContinuousClock.now
        var requests = 0
    }

    private func make(_ clock: Clock) -> KeyFrameRecovery {
        KeyFrameRecovery(now: { clock.now }) { clock.requests += 1 }
    }

    @Test func aFailureRequestsAKeyFrameAtOnce() {
        let clock = Clock()
        var recovery = make(clock)
        recovery.decoderFailed()
        #expect(clock.requests == 1)
    }

    @Test func requestsAtMostOncePerIntervalWhileFramesKeepDropping() {
        let clock = Clock()
        var recovery = make(clock)
        recovery.decoderFailed()
        recovery.decoderFailed()
        recovery.frameDropped()
        #expect(clock.requests == 1)

        clock.now += KeyFrameRecovery.interval
        recovery.frameDropped()
        #expect(clock.requests == 2)
    }

    @Test func droppedFramesRequestNothingOnceAFrameDecodes() {
        let clock = Clock()
        var recovery = make(clock)
        recovery.frameDropped()
        #expect(clock.requests == 0)

        recovery.decoderFailed()
        recovery.decoded()
        clock.now += KeyFrameRecovery.interval
        recovery.frameDropped()
        #expect(clock.requests == 1)
    }
}

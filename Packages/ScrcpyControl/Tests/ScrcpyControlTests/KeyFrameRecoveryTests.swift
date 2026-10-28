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

    @Test func aFailureRequestsAKeyFrameAtOnce() throws {
        let clock = Clock()
        var recovery = make(clock)
        try recovery.decoderFailed()
        #expect(clock.requests == 1)
    }

    @Test func requestsAtMostOncePerIntervalWhileFramesKeepDropping() throws {
        let clock = Clock()
        var recovery = make(clock)
        try recovery.decoderFailed()
        try recovery.decoderFailed()
        try recovery.frameDropped()
        #expect(clock.requests == 1)

        clock.now += KeyFrameRecovery.interval
        try recovery.frameDropped()
        #expect(clock.requests == 2)
    }

    @Test func droppedFramesRequestNothingOnceAFrameDecodes() throws {
        let clock = Clock()
        var recovery = make(clock)
        try recovery.frameDropped()
        #expect(clock.requests == 0)

        try recovery.decoderFailed()
        recovery.reset()
        clock.now += KeyFrameRecovery.interval
        try recovery.frameDropped()
        #expect(clock.requests == 1)
    }

    @Test func givesUpWhenNothingDecodesForTheWholeBound() throws {
        let clock = Clock()
        var recovery = make(clock)
        try recovery.decoderFailed()
        clock.now += KeyFrameRecovery.giveUpAfter - .milliseconds(1)
        try recovery.frameDropped()

        clock.now += .milliseconds(1)
        #expect(throws: ScrcpyConnectionError.undecodable) { try recovery.frameDropped() }
    }

    @Test func aDecodedFrameRestartsTheBound() throws {
        let clock = Clock()
        var recovery = make(clock)
        try recovery.decoderFailed()
        clock.now += KeyFrameRecovery.giveUpAfter - .milliseconds(1)
        recovery.reset()
        try recovery.decoderFailed()
        clock.now += KeyFrameRecovery.giveUpAfter - .milliseconds(1)
        try recovery.decoderFailed()
    }
}

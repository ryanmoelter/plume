import Testing
import Foundation
@testable import Plume

/// Covers the back-off after the sleep helper stops answering: delays double
/// up to a cap, the helper reads unresponsive after a few failures, and an
/// unloaded helper is re-registered once until it answers again.
struct SleepHelperRetryPolicyTests {
    @Test func delaysDoubleUpToTheCap() {
        var policy = SleepHelperRetryPolicy()
        let delays = (0..<9).map { _ in policy.recordFailure() }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60])
    }

    @Test func aLongFailureStreakStaysAtTheCap() {
        #expect(SleepHelperRetryPolicy.delay(afterFailures: 10_000) == SleepHelperRetryPolicy.maxDelay)
        #expect(SleepHelperRetryPolicy.delay(afterFailures: 0) == 0)
    }

    @Test func readsUnresponsiveOnlyAfterRepeatedFailures() {
        var policy = SleepHelperRetryPolicy()
        _ = policy.recordFailure()
        _ = policy.recordFailure()
        #expect(!policy.isUnresponsive)
        _ = policy.recordFailure()
        #expect(policy.isUnresponsive)
    }

    @Test func aSuccessResetsTheStreak() {
        var policy = SleepHelperRetryPolicy()
        for _ in 0..<5 { _ = policy.recordFailure() }
        policy.recordSuccess()
        #expect(!policy.isUnresponsive)
        let delay = policy.recordFailure()
        #expect(delay == 1)
    }

    @Test func aFailedReregisterReadsUnresponsiveUntilASuccess() {
        var policy = SleepHelperRetryPolicy()
        policy.markUnresponsive()
        #expect(policy.isUnresponsive)
        policy.recordSuccess()
        #expect(!policy.isUnresponsive)
    }

    @Test func aLoadedHelperIsNeverReregistered() {
        var policy = SleepHelperRetryPolicy()
        let claimed = policy.claimReregister(helperLoaded: true)
        #expect(!claimed)
        #expect(policy.hasCheckedLoad)
    }

    @Test func anUnloadedHelperIsReregisteredOnce() {
        var policy = SleepHelperRetryPolicy()
        let first = policy.claimReregister(helperLoaded: false)
        let second = policy.claimReregister(helperLoaded: false)
        #expect(first)
        #expect(!second)
    }

    @Test func aSuccessAllowsAnotherReregister() {
        var policy = SleepHelperRetryPolicy()
        _ = policy.claimReregister(helperLoaded: false)
        policy.recordSuccess()
        let again = policy.claimReregister(helperLoaded: false)
        #expect(again)
    }
}

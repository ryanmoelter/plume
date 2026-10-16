import Testing
@testable import Plume

/// Covers the reachability check the Keep Awake panel and Settings run as they
/// open: it asks only a registered, idle helper, never twice at once, and an
/// unreachable answer stands until the helper answers something else.
struct SleepHelperReachabilityCheckTests {
    @Test func asksOnlyAnEnabledIdleHelper() {
        var check = SleepHelperReachabilityCheck()
        let unregistered = check.beginCheck(serviceEnabled: false, isEngaged: false, isRecovering: false)
        let engaged = check.beginCheck(serviceEnabled: true, isEngaged: true, isRecovering: false)
        let recovering = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: true)
        let idle = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: false)
        #expect(!unregistered)
        #expect(!engaged)
        #expect(!recovering)
        #expect(idle)
    }

    @Test func neverAsksTwiceAtOnce() {
        var check = SleepHelperReachabilityCheck()
        let first = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: false)
        let overlapping = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: false)
        check.abandonCheck()
        let afterAbandoning = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: false)
        #expect(first)
        #expect(!overlapping)
        #expect(afterAbandoning)
    }

    @Test(arguments: [
        (SleepHelperVersionPolicy.Answer.unreachable, true),
        (.refused, false),
        (.build("33"), false),
    ])
    func onlyAnUnreachableAnswerReadsBroken(answer: SleepHelperVersionPolicy.Answer, broken: Bool) {
        var check = SleepHelperReachabilityCheck()
        _ = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: false)
        check.record(answer)
        #expect(check.isUnreachable == broken)
        #expect(!check.isChecking)
    }

    @Test func theAnswerStandsUntilTheNextCheckOrAReply() {
        var check = SleepHelperReachabilityCheck()
        _ = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: false)
        check.record(.unreachable)
        #expect(check.isUnreachable)

        _ = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: false)
        #expect(check.isUnreachable, "a check in flight keeps the last answer")
        check.record(.build("33"))
        #expect(!check.isUnreachable)

        _ = check.beginCheck(serviceEnabled: true, isEngaged: false, isRecovering: false)
        check.record(.unreachable)
        check.recordReached()
        #expect(!check.isUnreachable)
    }
}

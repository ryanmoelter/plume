import Foundation

/// Decides when to ask the sleep helper whether it answers at all, and holds
/// the answer.
///
/// `SMAppService` reads `.enabled` for a daemon launchd cannot spawn, so the
/// panel and Settings each ask once as they open, and the answer stands until
/// the next opening or until the helper answers something else. Every ask
/// makes launchd try to spawn the helper, so nothing asks on a timer or on
/// app activation.
nonisolated struct SleepHelperReachabilityCheck: Equatable, Sendable {
    private(set) var isChecking = false
    private(set) var isUnreachable = false

    /// An engaged helper has just answered, and a recovering one is being
    /// reinstalled, so neither needs asking.
    mutating func beginCheck(serviceEnabled: Bool, isEngaged: Bool, isRecovering: Bool) -> Bool {
        guard !isChecking, serviceEnabled, !isEngaged, !isRecovering else { return false }
        isChecking = true
        return true
    }

    mutating func record(_ answer: SleepHelperVersionPolicy.Answer) {
        isChecking = false
        isUnreachable = answer == .unreachable
    }

    /// For a check whose result no longer applies.
    mutating func abandonCheck() {
        isChecking = false
    }

    /// Any reply from the helper, or a reinstall that replaced it.
    mutating func recordReached() {
        isUnreachable = false
    }
}

import Foundation

/// How `DaemonLidSleepOverride` recovers when the helper stops answering.
///
/// `SMAppService.status` reports what Background Task Management approved,
/// not what launchd has loaded. A Homebrew upgrade boots the job out of
/// launchd while the approval stands, so the service reads `.enabled` and
/// every connection fails at lookup. Retrying at once turns that into a hot
/// loop, so failed attempts back off, launchd is asked whether the job is
/// loaded once per failure streak, and after a few failures the helper reads
/// as unresponsive.
nonisolated struct SleepHelperRetryPolicy: Equatable, Sendable {
    static let baseDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 60
    static let failuresBeforeUnresponsive = 3

    private(set) var consecutiveFailures = 0
    private(set) var hasCheckedLoad = false

    /// Records a failed attempt and returns how long to wait before the next.
    mutating func recordFailure() -> TimeInterval {
        consecutiveFailures += 1
        return Self.delay(afterFailures: consecutiveFailures)
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        hasCheckedLoad = false
    }

    /// Records the one load check of this streak, and whether to re-register.
    /// A re-register that did not help, or a helper launchd already has
    /// loaded, will not change on a second look.
    mutating func claimReregister(helperLoaded: Bool) -> Bool {
        guard !hasCheckedLoad else { return false }
        hasCheckedLoad = true
        return !helperLoaded
    }

    var isUnresponsive: Bool { consecutiveFailures >= Self.failuresBeforeUnresponsive }

    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 16)
        return min(baseDelay * pow(2, Double(exponent)), maxDelay)
    }
}

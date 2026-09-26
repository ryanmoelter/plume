import Foundation

/// How `DaemonLidSleepOverride` recovers when the helper stops answering.
///
/// `SMAppService.status` reports what Background Task Management approved,
/// not what launchd has loaded. A Homebrew upgrade boots the job out of
/// launchd while the approval stands, so the service reads `.enabled` and
/// every connection fails at lookup. Retrying at once turns that into a hot
/// loop, so failed attempts back off, the helper is re-registered at most once
/// per success, and after a few failures it reads as unavailable.
nonisolated struct SleepHelperRetryPolicy: Equatable, Sendable {
    static let baseDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 60
    static let failuresBeforeUnavailable = 3

    private(set) var consecutiveFailures = 0
    private(set) var hasReregistered = false

    /// Records a failed attempt and returns how long to wait before the next.
    mutating func recordFailure() -> TimeInterval {
        consecutiveFailures += 1
        return Self.delay(afterFailures: consecutiveFailures)
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        hasReregistered = false
    }

    /// Whether to re-register a helper launchd has not loaded. True at most
    /// once until the helper answers again, because a re-register that did not
    /// help will not help the second time either.
    mutating func claimReregister(helperLoaded: Bool) -> Bool {
        guard !helperLoaded, !hasReregistered else { return false }
        hasReregistered = true
        return true
    }

    var isUnavailable: Bool { consecutiveFailures >= Self.failuresBeforeUnavailable }

    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 16)
        return min(baseDelay * pow(2, Double(exponent)), maxDelay)
    }
}

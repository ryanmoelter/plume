import Foundation
import OSLog

nonisolated enum ClaudeUsagePollOutcome: Equatable, Sendable {
    case success
    case rateLimited(retryAfter: TimeInterval?)
    case failed
    /// Nothing to ask with — no login, or an expired token the CLI has not
    /// refreshed yet. Not a failure, so it never backs off.
    case skipped
}

/// When to ask the usage endpoint next. Pure so the timing is testable.
nonisolated enum ClaudeUsagePollSchedule {
    static let interval: TimeInterval = 20 * 60
    /// Credits are spent while a window is over its limit, so the balance
    /// moves fast enough then to be worth reading more often.
    static let overLimitInterval: TimeInterval = 5 * 60
    static let maxBackoff: TimeInterval = 60 * 60

    static func delay(after outcome: ClaudeUsagePollOutcome, consecutiveFailures: Int, isOverLimit: Bool) -> TimeInterval {
        let base = isOverLimit ? overLimitInterval : interval
        switch outcome {
        case .success, .skipped:
            return base
        case .failed:
            return backoff(base: base, failures: consecutiveFailures)
        case .rateLimited(let retryAfter):
            return max(retryAfter ?? 0, backoff(base: base, failures: consecutiveFailures))
        }
    }

    static func backoff(base: TimeInterval, failures: Int) -> TimeInterval {
        let doublings = min(max(failures - 1, 0), 16)
        return min(base * pow(2, Double(doublings)), max(maxBackoff, base))
    }

    /// Past this, a stream reading no longer says the account is still
    /// spending: nothing on this Mac has taken a turn in that long.
    static let overLimitReadingMaxAge: TimeInterval = 2 * 3600

    static func isOverLimit(_ snapshot: QuotaSnapshot?, now: Date) -> Bool {
        guard let snapshot, now.timeIntervalSince(snapshot.receivedAt) <= overLimitReadingMaxAge else { return false }
        func isFull(_ window: RateLimitInfo.Window?) -> Bool {
            guard let window, window.utilization >= 1 else { return false }
            return window.resetsAt.map { $0 > now } ?? true
        }
        let rateLimit = snapshot.rateLimit
        return rateLimit.isUsingOverage || isFull(rateLimit.fiveHour) || isFull(rateLimit.sevenDay)
    }
}

/// Reads the credit spend and the Fable window from Claude Code's usage
/// endpoint on a schedule, and records them in `QuotaStore`.
@MainActor
final class ClaudeUsagePoller {
    static let shared = ClaudeUsagePoller()

    /// How often the loop re-checks whether a poll is due, so a window going
    /// over its limit shortens the wait without waiting out the long one.
    static let checkInterval: Duration = .seconds(60)
    /// Debug builds are re-signed on every build, so each one would prompt
    /// for the CLI's Keychain item again. They poll only when asked to.
    static let debugOptInKey = "PlumeClaudeUsagePollInDebug"

    private let store: QuotaStore
    private let fetch: @Sendable (Date) async -> ClaudeUsageFetchResult
    private let settings: AppSettings
    private var loop: Task<Void, Never>?
    /// Bumped by `stop`, so a reply to a request sent before it is dropped.
    private var generation = 0
    private var isFetching = false
    private var lastAttempt: Date?
    private var lastOutcome: ClaudeUsagePollOutcome = .success
    private var consecutiveFailures = 0
#if DEBUG
    /// Set once a driver injects a reading, so a poll cannot overwrite it.
    var isSuspended = false
#endif

    init(
        store: QuotaStore = .shared,
        settings: AppSettings = .shared,
        fetch: @escaping @Sendable (Date) async -> ClaudeUsageFetchResult = { await ClaudeUsageClient().fetch(now: $0) }
    ) {
        self.store = store
        self.settings = settings
        self.fetch = fetch
    }

    func start() {
        guard loop == nil, settings.readsClaudeUsage, Self.shouldPoll() else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollIfDue()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        generation += 1
    }

    /// The Settings toggle: turning it on clears a declined Keychain prompt
    /// and polls straight away.
    func setEnabled(_ enabled: Bool) {
        settings.readsClaudeUsage = enabled
        stop()
        guard enabled else {
            store.forgetEndpointReadings()
            return
        }
        lastAttempt = nil
        consecutiveFailures = 0
        lastOutcome = .success
        start()
    }

    private static func shouldPoll() -> Bool {
        guard QuotaPersistence.sharedDefaults() != nil else { return false }
#if DEBUG
        return UserDefaults.standard.bool(forKey: debugOptInKey)
#else
        return true
#endif
    }

    private func isDue(now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let delay = ClaudeUsagePollSchedule.delay(
            after: lastOutcome,
            consecutiveFailures: consecutiveFailures,
            isOverLimit: ClaudeUsagePollSchedule.isOverLimit(store.snapshot, now: now)
        )
        return now.timeIntervalSince(lastAttempt) >= delay
    }

    func pollIfDue() async {
#if DEBUG
        guard !isSuspended else { return }
#endif
        let sentAt = Date()
        // A request still in flight from before a toggle holds the slot, so
        // turning polling off and on never runs two at once.
        guard settings.readsClaudeUsage, !isFetching, isDue(now: sentAt) else { return }
        lastAttempt = sentAt
        isFetching = true
        let sentGeneration = generation
        let result = await fetch(sentAt)
        isFetching = false
#if DEBUG
        guard !isSuspended else { return }
#endif
        guard sentGeneration == generation, settings.readsClaudeUsage else { return }
        apply(result, sentAt: sentAt)
    }

    private func apply(_ result: ClaudeUsageFetchResult, sentAt: Date) {
        switch result {
        case .reading(let reading):
            consecutiveFailures = 0
            lastOutcome = .success
            store.record(reading, at: sentAt)
        case .rateLimited(let retryAfter):
            consecutiveFailures += 1
            lastOutcome = .rateLimited(retryAfter: retryAfter)
        case .failed:
            consecutiveFailures += 1
            lastOutcome = .failed
        case .unauthorized:
            consecutiveFailures = 0
            lastOutcome = .skipped
        case .credentialsDenied:
            Log.agent.info("Claude usage polling turned off: Keychain access to the CLI's login was declined")
            settings.readsClaudeUsage = false
            stop()
            store.forgetEndpointReadings()
        }
    }
}

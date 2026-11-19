import Foundation
import Observation
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

/// What the quota row says about reading usage itself, so opting in always
/// shows something until the first reply lands.
enum ClaudeUsageStatus: Equatable {
    case idle
    case checking
    /// A sentence for the row's tooltip.
    case failed(String)

    /// For a driver reading the row's `plumeID` value.
    var description: String {
        switch self {
        case .idle: "idle"
        case .checking: "checking"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

/// Reads the credit spend and the Fable window from Claude Code's usage
/// endpoint on a schedule, and records them in `QuotaStore`.
@MainActor
@Observable
final class ClaudeUsagePoller {
    static let shared = ClaudeUsagePoller()

    /// How often the loop re-checks whether a poll is due, so a window going
    /// over its limit shortens the wait without waiting out the long one.
    static let checkInterval: Duration = .seconds(60)

    private let store: QuotaStore
    private let fetch: @Sendable (Date) async -> ClaudeUsageFetchResult
    private let settings: AppSettings
    private var loop: Task<Void, Never>?
    /// Bumped by `stop`, so a reply to a request sent before it is dropped.
    private var generation = 0
    private var isFetching = false
    /// Set by a dismissed Keychain prompt, so it isn't asked again this launch.
    private var isPausedThisLaunch = false
    /// Dismissed prompts that turn polling off.
    static let cancelsBeforeTurningOff = 2
    private var lastAttempt: Date?
    private var lastOutcome: ClaudeUsagePollOutcome = .success
    private var consecutiveFailures = 0
    /// Ordinary failures surface only between opting in and the first
    /// reading; after that the row keeps showing the last good one.
    private(set) var status: ClaudeUsageStatus = .idle
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
        guard loop == nil, settings.readsClaudeUsage, !isPausedThisLaunch, Self.shouldPoll() else { return }
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

    /// The Settings toggle and the quota row's offer: turning it on clears
    /// any declined or dismissed Keychain prompt and polls straight away.
    func setEnabled(_ enabled: Bool) {
        settings.readsClaudeUsage = enabled
        stop()
        guard enabled else {
            status = .idle
            store.forgetEndpointReadings()
            return
        }
#if DEBUG
        // A driver's injected readings would otherwise hold the poll off and
        // pass for real ones.
        isSuspended = false
        store.endInjection()
#endif
        status = .checking
        settings.claudeUsageKeychainCancels = 0
        isPausedThisLaunch = false
        lastAttempt = nil
        consecutiveFailures = 0
        lastOutcome = .success
        start()
    }

    /// Never under a test run, which would otherwise read the developer's
    /// own login.
    private static func shouldPoll() -> Bool {
        QuotaPersistence.sharedDefaults() != nil
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
        guard settings.readsClaudeUsage, !isPausedThisLaunch, !isFetching, isDue(now: sentAt) else { return }
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
            settings.claudeUsageKeychainCancels = 0
            consecutiveFailures = 0
            lastOutcome = .success
            status = .idle
            store.record(reading, at: sentAt)
        case .rateLimited(let retryAfter):
            consecutiveFailures += 1
            lastOutcome = .rateLimited(retryAfter: retryAfter)
            surface("Claude's usage service asked Plume to wait. Plume will try again.")
        case .failed:
            consecutiveFailures += 1
            lastOutcome = .failed
            surface("Plume couldn't reach Claude's usage service. It will try again.")
        case .unauthorized:
            consecutiveFailures = 0
            lastOutcome = .skipped
            surface("Claude Code isn't signed in, or its login has expired. Sign in with claude and Plume will try again.")
        case .credentialsDenied:
            Log.agent.info("Claude usage polling turned off: Keychain access to the CLI's login was declined")
            turnOff()
            status = .failed("Keychain access to Claude Code's login was declined, so Plume stopped reading usage.")
        case .credentialsCancelled:
            settings.claudeUsageKeychainCancels += 1
            if settings.claudeUsageKeychainCancels >= Self.cancelsBeforeTurningOff {
                Log.agent.info("Claude usage polling turned off: the Keychain prompt was dismissed twice")
                turnOff()
            } else {
                Log.agent.info("Claude usage polling paused until relaunch: the Keychain prompt was dismissed")
                isPausedThisLaunch = true
                stop()
            }
            status = .failed("The Keychain prompt was dismissed, so Plume couldn't read Claude Code's login.")
        }
    }

    private func surface(_ reason: String) {
        guard status != .idle else { return }
        status = .failed(reason)
    }

    private func turnOff() {
        settings.readsClaudeUsage = false
        stop()
        store.forgetEndpointReadings()
    }
}

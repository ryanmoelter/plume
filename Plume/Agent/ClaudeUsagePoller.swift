import Foundation
import Observation
import OSLog

nonisolated enum ClaudeUsagePollOutcome: Equatable, Sendable {
    case success
    case failed
    /// The CLI answered without rate limits. Not a failure, so it never
    /// backs off.
    case skipped
}

/// When to ask for usage next. Pure so the timing is testable.
///
/// Every 20 minutes, and also at the end of a Claude turn while a window is
/// over its limit, since credits are spent then and the balance moves with
/// each turn. Those turn-end polls are at most one per `turnEndThrottle`.
nonisolated enum ClaudeUsagePollSchedule {
    static let interval: TimeInterval = 20 * 60
    static let turnEndThrottle: TimeInterval = 2 * 60
    static let maxBackoff: TimeInterval = 60 * 60

    static func delay(after outcome: ClaudeUsagePollOutcome, consecutiveFailures: Int) -> TimeInterval {
        switch outcome {
        case .success, .skipped:
            return interval
        case .failed:
            return backoff(failures: consecutiveFailures)
        }
    }

    static func backoff(failures: Int) -> TimeInterval {
        let doublings = min(max(failures - 1, 0), 16)
        return min(interval * pow(2, Double(doublings)), maxBackoff)
    }

    static func isDue(now: Date, lastAttempt: Date?, outcome: ClaudeUsagePollOutcome, consecutiveFailures: Int) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= delay(after: outcome, consecutiveFailures: consecutiveFailures)
    }

    /// Whether a turn that just ended earns a poll. A failing fetch keeps its
    /// backoff rather than retrying every turn, and an account that cannot
    /// report usage waits for the regular poll.
    static func isDueAtTurnEnd(
        now: Date,
        isOverLimit: Bool,
        lastAttempt: Date?,
        consecutiveFailures: Int,
        lastOutcome: ClaudeUsagePollOutcome = .success
    ) -> Bool {
        guard isOverLimit, lastOutcome != .skipped else { return false }
        guard let lastAttempt else { return true }
        let wait = consecutiveFailures > 0 ? backoff(failures: consecutiveFailures) : turnEndThrottle
        return now.timeIntervalSince(lastAttempt) >= wait
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

/// What the quota row says about reading usage itself, so turning it on
/// always shows something until the first reply lands.
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

/// Reads the credit spend and the Fable window through Claude Code's
/// `get_usage` request on a schedule, and records them in `QuotaStore`.
@MainActor
@Observable
final class ClaudeUsagePoller {
    static let shared = ClaudeUsagePoller()

    /// How often the loop re-checks whether a poll is due.
    static let checkInterval: Duration = .seconds(60)

    private let store: QuotaStore
    private let fetch: @Sendable (Date) async -> ClaudeUsageFetchResult
    private let settings: AppSettings
    private let isClaudeAvailable: @Sendable () async -> Bool
    private var loop: Task<Void, Never>?
    /// Bumped by `stop`, so a reply to a request sent before it is dropped.
    private var generation = 0
    private var isFetching = false
    private var lastAttempt: Date?
    private var lastOutcome: ClaudeUsagePollOutcome = .success
    private var consecutiveFailures = 0
    /// Ordinary failures surface only between turning reading on and the
    /// first reading; after that the row keeps showing the last good one.
    private(set) var status: ClaudeUsageStatus = .idle
#if DEBUG
    /// Set once a driver injects a reading, so a poll cannot overwrite it.
    var isSuspended = false
#endif

    init(
        store: QuotaStore = .shared,
        settings: AppSettings = .shared,
        fetch: (@Sendable (Date) async -> ClaudeUsageFetchResult)? = nil,
        isClaudeAvailable: (@Sendable () async -> Bool)? = nil
    ) {
        self.store = store
        self.settings = settings
        if let isClaudeAvailable {
            self.isClaudeAvailable = isClaudeAvailable
        } else if fetch == nil {
            self.isClaudeAvailable = { await Self.claudeIsInstalled() }
        } else {
            self.isClaudeAvailable = { true }
        }
        let client = ClaudeUsageClient(workingDirectory: AppPaths.applicationSupport.appending(path: "usage"))
        self.fetch = fetch ?? { _ in await client.fetch() }
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

    /// The Settings toggle: turning it on polls straight away.
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
        lastAttempt = nil
        consecutiveFailures = 0
        lastOutcome = .success
        start()
    }

    /// A Claude tab's turn ended. Polls only while the account is over a
    /// limit; the schedule decides.
    func turnEnded() {
        guard loop != nil else { return }
        Task { await pollAtTurnEnd() }
    }

    func pollAtTurnEnd() async {
        let now = Date()
        let isDue = ClaudeUsagePollSchedule.isDueAtTurnEnd(
            now: now,
            isOverLimit: ClaudeUsagePollSchedule.isOverLimit(store.snapshot, now: now),
            lastAttempt: lastAttempt,
            consecutiveFailures: consecutiveFailures,
            lastOutcome: lastOutcome
        )
        guard isDue else { return }
        await poll(at: now)
    }

    /// Looks again when the cached answer says no, so installing Claude Code
    /// starts polling without a relaunch.
    private static func claudeIsInstalled() async -> Bool {
        let availability = AgentCLIAvailability.shared
        if await availability.load().contains(.claudeCode) { return true }
        return await availability.refresh().contains(.claudeCode)
    }

    /// Never under a test run, which would otherwise read the developer's
    /// own account.
    private static func shouldPoll() -> Bool {
        QuotaPersistence.sharedDefaults() != nil
    }

    func pollIfDue() async {
        let now = Date()
        let isDue = ClaudeUsagePollSchedule.isDue(
            now: now, lastAttempt: lastAttempt, outcome: lastOutcome, consecutiveFailures: consecutiveFailures
        )
        guard isDue else { return }
        await poll(at: now)
    }

    private func poll(at sentAt: Date) async {
#if DEBUG
        guard !isSuspended else { return }
#endif
        // A request still in flight from before a toggle holds the slot, so
        // turning polling off and on never runs two at once.
        guard settings.readsClaudeUsage, !isFetching else { return }
        lastAttempt = sentAt
        isFetching = true
        let sentGeneration = generation
        guard await isClaudeAvailable() else {
            isFetching = false
            guard sentGeneration == generation else { return }
            lastOutcome = .skipped
            surface("Plume can't find Claude Code, so it can't read usage.")
            return
        }
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
            status = .idle
            store.record(reading, at: sentAt)
        case .failed:
            consecutiveFailures += 1
            lastOutcome = .failed
            surface("Plume couldn't read usage from Claude Code. It will try again.")
        case .unavailable:
            consecutiveFailures = 0
            lastOutcome = .skipped
            surface("Claude Code's login can't report usage. Sign in again with claude and Plume will try again.")
        }
    }

    private func surface(_ reason: String) {
        guard status != .idle else { return }
        status = .failed(reason)
    }
}

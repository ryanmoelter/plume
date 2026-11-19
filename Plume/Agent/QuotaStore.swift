import AppKit
import Foundation
import Observation

/// The account's 5h, 7d and Fable quota windows and its usage-credit spend,
/// shared by every chat.
///
/// The windows are a property of the account, not of a conversation, but they
/// only arrive as `rate_limit_event` messages inside whichever session happens
/// to be taking a turn. A chat that has not heard in an hour would otherwise
/// show an hour-old reading, so every session records what it hears here and
/// every view reads from here.
///
/// There is no key: the quotas are global.
///
/// The latest reading persists across launches, so the meters show the
/// last-known quota before any session has taken a turn.
@MainActor
@Observable
final class QuotaStore {
    static let shared = QuotaStore(defaults: QuotaPersistence.sharedDefaults())

    private(set) var snapshot: QuotaSnapshot?

    /// Advanced by the tick so the reset labels stay current while no message
    /// is arriving. Views read it instead of `Date()` so their rendering stays
    /// a function of observable state.
    private(set) var now = Date()

    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var focusObservers: [NSObjectProtocol] = []
    /// Nil keeps the store in memory only, which is what tests want.
    @ObservationIgnored private let defaults: UserDefaults?
    static let defaultsKey = "claudeQuotaSnapshot"

    init(defaults: UserDefaults? = nil, now: Date = Date()) {
        self.defaults = defaults
        self.now = now
        snapshot = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(QuotaSnapshot.self, from: $0) }?
            .restored(now: now)
    }

    func record(_ rateLimit: RateLimitInfo, at date: Date = Date()) {
        let hasWindows = rateLimit.fiveHour != nil || rateLimit.sevenDay != nil
        // The windows go missing from a payload that reports neither, which is
        // not the same as the account having no quota — keep the last reading.
        guard hasWindows || rateLimit.fable != nil else { return }
        let previous = snapshot
        var next = hasWindows
            ? QuotaSnapshot(rateLimit: rateLimit, receivedAt: date)
            : previous ?? .empty(at: date)
        next.credit = previous?.credit
        next.creditReceivedAt = previous?.creditReceivedAt
        if let fable = rateLimit.fable {
            next = next.with(fable: fable, receivedAt: date)
        } else if let previous {
            // Only a Fable turn reports the Fable window.
            next = next.with(fable: previous.rateLimit.fable, receivedAt: previous.fableReceivedAt)
        }
#if DEBUG
        if hasWindows { injection?.overridesOverage = false }
#endif
        persist(next)
        now = date
    }

    /// A reading from the usage endpoint, which brings what the stream never
    /// does: the credit spend, and the Fable window between Fable turns.
    /// `date` is when the request was sent, so a stream reading that arrives
    /// while it is in flight is newer than the reply.
    func record(_ usage: ClaudeUsageReading, at date: Date = Date()) {
        guard usage.fable != nil || usage.credit != nil else { return }
        var next = snapshot ?? .empty(at: date)
        if let fable = usage.fable, next.fableHeardAt <= date {
            next = next.with(fable: fable, receivedAt: date)
        }
        if let credit = usage.credit {
            next.credit = credit
            next.creditReceivedAt = date
        }
        persist(next)
    }

#if DEBUG
    /// What a driver's injected reading replaced, so the readings on disk
    /// stay the real ones.
    private struct Injection {
        let baseline: QuotaSnapshot?
        var overridesOverage: Bool
    }

    @ObservationIgnored private var injection: Injection?

    /// Seeds the Fable window and credit for a driver; nil clears either.
    func inject(fable: RateLimitInfo.Window?, credit: UsageCredit?, isUsingOverage: Bool?, at date: Date = Date()) {
        if injection == nil {
            injection = Injection(baseline: snapshot, overridesOverage: false)
        }
        if isUsingOverage != nil { injection?.overridesOverage = true }
        let base = snapshot ?? .empty(at: date)
        var next = QuotaSnapshot(
            rateLimit: RateLimitInfo(
                fiveHour: base.rateLimit.fiveHour,
                sevenDay: base.rateLimit.sevenDay,
                isUsingOverage: isUsingOverage ?? base.rateLimit.isUsingOverage
            ),
            receivedAt: base.receivedAt
        ).with(fable: fable, receivedAt: date)
        next.credit = credit
        next.creditReceivedAt = credit == nil ? nil : date
        snapshot = next
        now = date
    }

    private func withoutInjection(_ snapshot: QuotaSnapshot) -> QuotaSnapshot {
        guard let injection else { return snapshot }
        let baseline = injection.baseline
        var real = QuotaSnapshot(
            rateLimit: RateLimitInfo(
                fiveHour: snapshot.rateLimit.fiveHour,
                sevenDay: snapshot.rateLimit.sevenDay,
                isUsingOverage: injection.overridesOverage
                    ? baseline?.rateLimit.isUsingOverage ?? false
                    : snapshot.rateLimit.isUsingOverage
            ),
            receivedAt: snapshot.receivedAt
        ).with(fable: baseline?.rateLimit.fable, receivedAt: baseline?.fableReceivedAt)
        real.credit = baseline?.credit
        real.creditReceivedAt = baseline?.creditReceivedAt
        return real
    }
#endif

    private func persist(_ snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
#if DEBUG
        let snapshot = withoutInjection(snapshot)
#endif
        if let defaults, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Starts the once-a-minute tick that keeps the reset labels, the pacing
    /// mark and the staleness dimming current, and the focus watch that
    /// catches a return the tick would answer late. Idempotent, so every view
    /// can call it.
    func startTicking() {
        startObservingFocus()
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: QuotaFreshness.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        // A menu or a resize would otherwise hold the label back a whole minute.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        stopObservingFocus()
    }

    /// Re-reads the clock when the app gains or loses focus, so a window
    /// coming back after a while shows the pacing it should rather than
    /// whatever the tick last left.
    ///
    /// The tick is suspended while the app is inactive on some setups, and it
    /// only ever fires on its own schedule — so without this, the first frame
    /// after a return can be up to a whole interval stale. Nothing re-reads
    /// below `focusRefreshInterval`, since the tick has it covered and
    /// redrawing on every app switch would be churn.
    private func startObservingFocus() {
        guard focusObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ]
        focusObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshIfStale() }
            }
        }
    }

    private func stopObservingFocus() {
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
    }

    private func refreshIfStale() {
        let date = Date()
        guard date.timeIntervalSince(now) >= QuotaFreshness.focusRefreshInterval else { return }
        now = date
    }
}

enum QuotaPersistence {
    /// None under a test run: the test host is the Debug app, so `.standard`
    /// is the running Debug build's own defaults, and a test that feeds a
    /// session a quota would overwrite the reading it restores at launch.
    static func sharedDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTestHost: Bool = NSClassFromString("XCTestCase") != nil
    ) -> UserDefaults? {
        environment["XCTestConfigurationFilePath"] == nil && !isTestHost ? .standard : nil
    }
}

struct QuotaSnapshot: Equatable, Codable {
    let rateLimit: RateLimitInfo
    /// When the 5h and 7d windows were heard.
    let receivedAt: Date
    /// When `rateLimit.fable` was heard, which can be later than
    /// `receivedAt`: the usage endpoint reports it between turns.
    var fableReceivedAt: Date?
    var credit: UsageCredit?
    var creditReceivedAt: Date?

    static func empty(at date: Date) -> QuotaSnapshot {
        QuotaSnapshot(rateLimit: RateLimitInfo(fiveHour: nil, sevenDay: nil, isUsingOverage: false), receivedAt: date)
    }

    /// Whether it holds anything heard, as opposed to placeholders.
    var hasReading: Bool {
        rateLimit.fiveHour != nil || rateLimit.sevenDay != nil || rateLimit.fable != nil || credit?.usedCents != nil
    }

    var fableHeardAt: Date {
        rateLimit.fable == nil ? .distantPast : fableReceivedAt ?? receivedAt
    }

    /// The newest of the readings it holds, which is what says whether the
    /// row as a whole has gone quiet.
    var lastHeardAt: Date {
        let windowsHeardAt = rateLimit.fiveHour != nil || rateLimit.sevenDay != nil ? receivedAt : .distantPast
        let creditHeardAt = credit == nil ? .distantPast : creditReceivedAt ?? receivedAt
        let newest = max(windowsHeardAt, fableHeardAt, creditHeardAt)
        return newest == .distantPast ? receivedAt : newest
    }

    func with(fable: RateLimitInfo.Window?, receivedAt fableDate: Date?) -> QuotaSnapshot {
        QuotaSnapshot(
            rateLimit: RateLimitInfo(
                fiveHour: rateLimit.fiveHour,
                sevenDay: rateLimit.sevenDay,
                isUsingOverage: rateLimit.isUsingOverage,
                fable: fable
            ),
            receivedAt: receivedAt,
            fableReceivedAt: fable == nil ? nil : fableDate,
            credit: credit,
            creditReceivedAt: creditReceivedAt
        )
    }

    /// A persisted reading as it should show at launch: any window that has
    /// reset since it was saved reads 0%, with no reset time until a live
    /// reading brings one.
    func restored(now: Date) -> QuotaSnapshot {
        func restore(_ window: RateLimitInfo.Window?, length: TimeInterval, heardAt: Date) -> RateLimitInfo.Window? {
            guard let window else { return nil }
            let refilled = QuotaFreshness.hasRefilled(
                resetsAt: window.resetsAt, receivedAt: heardAt, windowLength: length, now: now
            )
            return refilled ? .init(utilization: 0, resetsAt: nil) : window
        }
        // A reading from a billing period that has ended says nothing about
        // the new one.
        let creditPeriodEnded = credit?.resetsAt.map { $0 <= now } ?? false
        let fiveHour = restore(rateLimit.fiveHour, length: QuotaWindowLength.fiveHour, heardAt: receivedAt)
        let sevenDay = restore(rateLimit.sevenDay, length: QuotaWindowLength.sevenDay, heardAt: receivedAt)
        // Overage is spent only while a window is full, so it ends with the
        // refill.
        let windowsRefilled = (fiveHour != rateLimit.fiveHour || sevenDay != rateLimit.sevenDay)
            && [fiveHour, sevenDay].allSatisfy { ($0?.utilization ?? 0) < 1 }
        return QuotaSnapshot(
            rateLimit: RateLimitInfo(
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                isUsingOverage: rateLimit.isUsingOverage && !windowsRefilled,
                fable: restore(rateLimit.fable, length: QuotaWindowLength.sevenDay, heardAt: fableReceivedAt ?? receivedAt)
            ),
            receivedAt: receivedAt,
            fableReceivedAt: fableReceivedAt,
            credit: creditPeriodEnded ? nil : credit,
            creditReceivedAt: creditPeriodEnded ? nil : creditReceivedAt
        )
    }
}

/// How a quota reading ages: the tick that refreshes its labels, and the point
/// past which it is too old to present at full confidence.
///
/// Pure so the timing is testable without a view or a clock.
enum QuotaFreshness {
    static let tickInterval: TimeInterval = 60
    /// How long the clock has to have gone unread before a focus change is
    /// worth re-reading it for.
    static let focusRefreshInterval: TimeInterval = 3 * 60
    static let staleAfter: TimeInterval = 30 * 60

    /// Two missed polls of the usage endpoint.
    static let creditStaleAfter: TimeInterval = 2 * ClaudeUsagePollSchedule.interval

    static func isStale(receivedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) > staleAfter
    }

    static func isCreditStale(receivedAt: Date?, now: Date) -> Bool {
        guard let receivedAt else { return true }
        return now.timeIntervalSince(receivedAt) > creditStaleAfter
    }

    /// A live reading whose reset time has passed is not zeroed: the session
    /// is running, so the next message will report the refill, and until then
    /// the reading stands and the countdown bottoms out at `0m`. Only a
    /// reading restored at launch zeroes, through `hasRefilled`, since nothing
    /// may report for a long while.
    static func resetLabel(resetsAt: Date?, now: Date, fallback: String) -> String {
        guard let resetsAt else { return fallback }
        let seconds = max(resetsAt.timeIntervalSince(now), 0)
        if seconds >= 86400 { return "\(Int((seconds + 43200) / 86400))d" }
        if seconds >= 3600 { return "\(Int((seconds + 1800) / 3600))h" }
        return "\(Int((seconds + 30) / 60))m"
    }

    /// Whether a window has reset since it was read: its reset time has
    /// passed, or with none, a whole window length has since `receivedAt`.
    /// A window with neither is never judged refilled.
    static func hasRefilled(resetsAt: Date?, receivedAt: Date, windowLength: TimeInterval?, now: Date) -> Bool {
        if let resetsAt { return resetsAt <= now }
        guard let windowLength, windowLength > 0 else { return false }
        return receivedAt.addingTimeInterval(windowLength) <= now
    }

    /// How far through the window the clock is, 0–1, or nil when nothing says.
    ///
    /// The stream reports when a window resets but never when it opened, so
    /// the elapsed share is derived from the window's own length. Reading it
    /// against `utilization` is the point: a fill well behind the pacing mark
    /// is spending slower than the window refills, and one ahead of it is
    /// spending faster than the window will forgive.
    static func pacing(resetsAt: Date?, now: Date, window: TimeInterval) -> Double? {
        guard let resetsAt, window > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        // A reset already past says the window has refilled and no message has
        // reported it yet; claiming a full bar would overstate what is known.
        guard remaining > 0 else { return nil }
        let elapsed = window - remaining
        return Swift.min(Swift.max(elapsed / window, 0), 1)
    }

    /// The absolute time the window resets, which is what a tooltip says — the
    /// relative countdown is already the visible reading. A reset on a later
    /// day is named by weekday: only the 7d window ever spans days, and it
    /// never reaches a week out, so the day name is unambiguous and reads
    /// faster than a date. Either form carries its own "at", so it follows
    /// "Resets " directly.
    static func absoluteResetLabel(resetsAt: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        guard !Calendar.current.isDate(resetsAt, inSameDayAs: now) else {
            return "at \(formatter.string(from: resetsAt))"
        }
        let weekday = DateFormatter()
        weekday.locale = .current
        weekday.setLocalizedDateFormatFromTemplate("EEEE")
        return "\(weekday.string(from: resetsAt)) at \(formatter.string(from: resetsAt))"
    }
}

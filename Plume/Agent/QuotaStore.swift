import AppKit
import Foundation
import Observation

/// The account's 5h and 7d quota windows, shared by every chat.
///
/// The windows are a property of the account, not of a conversation, but they
/// only arrive as `rate_limit_event` messages inside whichever session happens
/// to be taking a turn. A chat that has not heard in an hour would otherwise
/// show an hour-old reading, so every session records what it hears here and
/// every view reads from here.
///
/// There is no key: the quotas are global.
@MainActor
@Observable
final class QuotaStore {
    static let shared = QuotaStore()

    private(set) var snapshot: QuotaSnapshot?

    /// Advanced by the tick so the reset labels stay current while no message
    /// is arriving. Views read it instead of `Date()` so their rendering stays
    /// a function of observable state.
    private(set) var now = Date()

    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var focusObservers: [NSObjectProtocol] = []

    init() {}

    func record(_ rateLimit: RateLimitInfo, at date: Date = Date()) {
        // The windows go missing from a payload that reports neither, which is
        // not the same as the account having no quota — keep the last reading.
        guard rateLimit.fiveHour != nil || rateLimit.sevenDay != nil else { return }
        snapshot = QuotaSnapshot(rateLimit: rateLimit, receivedAt: date)
        now = date
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

struct QuotaSnapshot: Equatable {
    let rateLimit: RateLimitInfo
    let receivedAt: Date
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

    static func isStale(receivedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) > staleAfter
    }

    /// A reset time in the past is not a zeroed window — the quota does refill,
    /// but nothing says so until the next message arrives, and claiming 0%
    /// would be inventing data. The reading stands and the countdown bottoms
    /// out at `0m`.
    static func resetLabel(resetsAt: Date?, now: Date, fallback: String) -> String {
        guard let resetsAt else { return fallback }
        let seconds = max(resetsAt.timeIntervalSince(now), 0)
        if seconds >= 86400 { return "\(Int((seconds + 43200) / 86400))d" }
        if seconds >= 3600 { return "\(Int((seconds + 1800) / 3600))h" }
        return "\(Int((seconds + 30) / 60))m"
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
    /// faster than a date.
    static func absoluteResetLabel(resetsAt: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        guard !Calendar.current.isDate(resetsAt, inSameDayAs: now) else {
            return formatter.string(from: resetsAt)
        }
        let weekday = DateFormatter()
        weekday.locale = .current
        weekday.setLocalizedDateFormatFromTemplate("EEEE")
        return "\(weekday.string(from: resetsAt)) at \(formatter.string(from: resetsAt))"
    }
}

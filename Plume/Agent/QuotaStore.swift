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

    init() {}

    func record(_ rateLimit: RateLimitInfo, at date: Date = Date()) {
        // The windows go missing from a payload that reports neither, which is
        // not the same as the account having no quota — keep the last reading.
        guard rateLimit.fiveHour != nil || rateLimit.sevenDay != nil else { return }
        snapshot = QuotaSnapshot(rateLimit: rateLimit, receivedAt: date)
        now = date
    }

    /// Starts the once-a-minute tick that keeps the reset labels and the
    /// staleness dimming current. Idempotent, so every view can call it.
    func startTicking() {
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
    static let staleAfter: TimeInterval = 30 * 60
    static let staleOpacity: Double = 0.45

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

    /// The absolute time the window resets, which is what a tooltip says — the
    /// relative countdown is already the visible reading.
    static func absoluteResetLabel(resetsAt: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = Calendar.current.isDate(resetsAt, inSameDayAs: now) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: resetsAt)
    }
}

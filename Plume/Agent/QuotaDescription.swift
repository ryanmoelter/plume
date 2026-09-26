import Foundation

/// One quota window in words, the form every quota tooltip and popover uses:
/// a title naming the provider and timeframe, then how much of the window is
/// spent, how much of it has elapsed, how long ago the reading arrived (once
/// that reading is stale), then when it resets — each its own line. A value
/// nothing reports is left out rather than printed as unknown.
struct QuotaWindowSummary: Equatable {
    /// E.g. "Claude 5h quota" or "Codex 7d quota" — the timeframe lives here
    /// rather than in the usage line, so the usage line can say just the
    /// percent.
    let title: String
    let usagePercent: Int
    let elapsedPercent: Int?
    /// Only set once the reading is stale — see `QuotaFreshness.staleAfter`.
    /// A fresh reading needs no disclaimer about its age.
    let lastHeard: String?
    /// The absolute reset time or date, e.g. "at 3:45 PM" — unprefixed, so a
    /// caller can bold it inside "Resets …" without reparsing the string.
    let reset: String?

    var lines: [String] {
        [title, "\(usagePercent)% used"]
            + [elapsedPercent.map { "\($0)% of time elapsed" }, lastHeard, reset.map { "Resets \($0)" }]
                .compactMap { $0 }
    }

    var text: String { lines.joined(separator: "\n") }
}

enum QuotaDescription {
    static func summary(
        provider: String,
        timeframe: String?,
        utilization: Double,
        resetsAt: Date?,
        windowLength: TimeInterval?,
        receivedAt: Date?,
        now: Date
    ) -> QuotaWindowSummary {
        let title = ([provider] + [timeframe].compactMap { $0 }).joined(separator: " ") + " quota"
        let usagePercent = Int((utilization * 100).rounded())
        let elapsedPercent = windowLength
            .flatMap { QuotaFreshness.pacing(resetsAt: resetsAt, now: now, window: $0) }
            .map { Int(($0 * 100).rounded()) }
        let lastHeard = receivedAt.flatMap { received in
            QuotaFreshness.isStale(receivedAt: received, now: now)
                ? "(last heard \(relativeLastHeard(receivedAt: received, now: now)))"
                : nil
        }
        let reset = resetsAt.map { QuotaFreshness.absoluteResetLabel(resetsAt: $0, now: now) }
        return QuotaWindowSummary(title: title, usagePercent: usagePercent, elapsedPercent: elapsedPercent, lastHeard: lastHeard, reset: reset)
    }

    /// `RelativeDateTimeFormatter`'s short form ("35 min. ago"). Only ever
    /// called once a reading is already past `QuotaFreshness.staleAfter`, so
    /// there is no "just now" case to special-case here.
    private static func relativeLastHeard(receivedAt: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: receivedAt, relativeTo: now)
    }

    /// `300` reads `5h` and `10080` reads `7d`: the largest whole unit.
    static func timeframe(minutes: Int) -> String {
        if minutes > 0 && minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes > 0 && minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    static func tooltip(_ summaries: [QuotaWindowSummary]) -> String {
        summaries.map(\.text).joined(separator: "\n")
    }
}

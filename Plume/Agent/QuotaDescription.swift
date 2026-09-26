import Foundation

/// One quota window in words, the form every quota tooltip and popover uses:
/// how much of which window is spent, how much of it has elapsed, how long
/// ago the reading arrived, then when it resets — each its own line. A value
/// nothing reports is left out rather than printed as unknown.
struct QuotaWindowSummary: Equatable {
    let usage: String
    let elapsed: String?
    let lastHeard: String?
    let reset: String?

    var lines: [String] { [usage] + [elapsed, lastHeard, reset].compactMap { $0 } }
    var text: String { lines.joined(separator: "\n") }
}

enum QuotaDescription {
    static func summary(
        timeframe: String?,
        utilization: Double,
        resetsAt: Date?,
        windowLength: TimeInterval?,
        receivedAt: Date?,
        now: Date
    ) -> QuotaWindowSummary {
        let quota = timeframe.map { "\($0) quota" } ?? "quota"
        let usage = "\(Int((utilization * 100).rounded()))% of \(quota) used"
        let elapsed = windowLength
            .flatMap { QuotaFreshness.pacing(resetsAt: resetsAt, now: now, window: $0) }
            .map { "\(Int(($0 * 100).rounded()))% of time elapsed" }
        let lastHeard = receivedAt.map { "(last heard \(relativeLastHeard(receivedAt: $0, now: now)))" }
        let reset = resetsAt.map { "Resets at \(QuotaFreshness.absoluteResetLabel(resetsAt: $0, now: now))" }
        return QuotaWindowSummary(usage: usage, elapsed: elapsed, lastHeard: lastHeard, reset: reset)
    }

    /// "just now" under a minute, otherwise `RelativeDateTimeFormatter`'s
    /// short form ("5 min. ago") — a relative reading, not a stale warning.
    private static func relativeLastHeard(receivedAt: Date, now: Date) -> String {
        guard now.timeIntervalSince(receivedAt) >= 60 else { return "just now" }
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

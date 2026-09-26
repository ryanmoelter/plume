import Foundation

/// One quota window in words, the form every quota tooltip and popover uses:
/// how much of which window is spent against how much of it has elapsed, then
/// when it resets. A value nothing reports is left out rather than printed as
/// unknown.
struct QuotaWindowSummary: Equatable {
    let usage: String
    let reset: String?

    var lines: [String] { [usage] + (reset.map { [$0] } ?? []) }
    var text: String { lines.joined(separator: "\n") }
}

enum QuotaDescription {
    static func summary(
        timeframe: String?,
        utilization: Double,
        resetsAt: Date?,
        windowLength: TimeInterval?,
        isStale: Bool,
        now: Date
    ) -> QuotaWindowSummary {
        let quota = timeframe.map { "\($0) quota" } ?? "quota"
        var usage = "\(Int((utilization * 100).rounded()))% of \(quota) used"
        if let windowLength,
           let elapsed = QuotaFreshness.pacing(resetsAt: resetsAt, now: now, window: windowLength) {
            usage += ", \(Int((elapsed * 100).rounded()))% of time elapsed"
        }
        if isStale { usage += " (last heard over 30 minutes ago)" }
        let reset = resetsAt.map { "Resetting at \(QuotaFreshness.absoluteResetLabel(resetsAt: $0, now: now))" }
        return QuotaWindowSummary(usage: usage, reset: reset)
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

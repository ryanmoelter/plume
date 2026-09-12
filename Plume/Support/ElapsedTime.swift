import Foundation

/// How long something has been going, in the coarsest terms that still say it.
///
/// Coarse on purpose: a live clock redraws whenever its view does, and a
/// seconds-precise figure past the first minute would rewrite every row for a
/// digit nobody reads.
nonisolated enum ElapsedTime {
    static func formatted(_ elapsed: TimeInterval) -> String {
        let seconds = Int(max(elapsed, 0).rounded())
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    /// How often a clock showing `elapsed` has to redraw to stay honest: once
    /// a second while it counts seconds, once a minute after that.
    static func tickInterval(for elapsed: TimeInterval) -> TimeInterval {
        elapsed < 60 ? 1 : 60
    }
}

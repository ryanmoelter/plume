import SwiftUI

/// Ticks once a second while the text counts seconds, then once a minute.
///
/// A plain `.periodic` fixes its rate at the first render, which would leave
/// a clock that started in its first minute redrawing every second for hours.
struct ElapsedSchedule: TimelineSchedule {
    let since: Date

    /// An upper bound on the gap between ticks, for a caller that changes
    /// something other than the elapsed figure and so needs to redraw while
    /// the clock itself has gone quiet.
    var maximumInterval: TimeInterval = .infinity

    func entries(from startDate: Date, mode: Mode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let entry = next
            let interval = min(
                ElapsedTime.tickInterval(for: entry.timeIntervalSince(since)),
                maximumInterval
            )
            next = entry.addingTimeInterval(interval)
            return entry
        }
    }
}

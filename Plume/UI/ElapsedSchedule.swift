import SwiftUI

/// Ticks once a second while the text counts seconds, then once a minute.
///
/// A plain `.periodic` fixes its rate at the first render, which would leave
/// a clock that started in its first minute redrawing every second for hours.
struct ElapsedSchedule: TimelineSchedule {
    let since: Date

    func entries(from startDate: Date, mode: Mode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let entry = next
            next = entry.addingTimeInterval(
                ElapsedTime.tickInterval(for: entry.timeIntervalSince(since))
            )
            return entry
        }
    }
}

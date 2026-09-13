import Foundation

/// Formats a message's timestamp against the moment it is read, so a reply
/// from today reads as a time alone and an older one gains the date it needs
/// to be placed. A timestamp always carries its time; only the date varies.
///
/// The reference date is a parameter rather than `Date()` so the day and year
/// boundaries can be tested. Day comparison goes through `Calendar`, since a
/// DST day is not 24 hours and interval arithmetic silently gets it wrong.
///
/// The formatted time separates its minutes from AM/PM with a narrow no-break
/// space, so a caller comparing the result to a literal has to use one too.
enum ChatTimestampFormat {
    /// - today: the time alone.
    /// - yesterday: the word and the time.
    /// - earlier: month and day with the time, gaining the year only outside
    ///   `now`'s.
    nonisolated static func string(
        for date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = date.formatted(style(calendar, locale).hour().minute())
        // `isDateInToday` measures against the real clock, not `now`, so the
        // days are compared directly instead.
        let daysApart = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day
        if daysApart == 0 {
            return time
        }
        if daysApart == 1 {
            return "Yesterday, \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let dayAndMonth = style(calendar, locale).month(.abbreviated).day()
        let day = date.formatted(sameYear ? dayAndMonth : dayAndMonth.year())
        return "\(day), \(time)"
    }

    /// The caller's calendar carries the time zone the day comparisons used,
    /// so the rendered string has to agree with it.
    private nonisolated static func style(_ calendar: Calendar, _ locale: Locale) -> Date.FormatStyle {
        var style = Date.FormatStyle(locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        return style
    }
}

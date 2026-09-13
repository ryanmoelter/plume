import Foundation
import Testing
@testable import Plume

/// The message footer's timestamp always carries its time, and gains the date
/// once the message is no longer from today: the word "Yesterday" the day
/// before, a month and day further back, and the year outside the reading
/// year. A fixed calendar, time zone and locale keep the expected strings
/// stable wherever the tests run.
struct ChatTimestampFormatTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private let locale = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// The formatter separates the minutes from AM/PM with a narrow no-break
    /// space. Folding it to a plain one keeps the expected strings below
    /// readable and lets them survive a change of separator.
    private func string(_ date: Date, now: Date) -> String {
        ChatTimestampFormat.string(for: date, now: now, calendar: calendar, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func todayShowsTheTimeAlone() {
        let now = date(2026, 9, 13, 15, 30)
        #expect(string(date(2026, 9, 13, 9, 5), now: now) == "9:05 AM")
    }

    @Test func yesterdayShowsTheWordAndTheTime() {
        #expect(string(date(2026, 9, 12, 23, 59), now: date(2026, 9, 13, 15, 30)) == "Yesterday, 11:59 PM")
    }

    @Test func earlierThisYearShowsMonthAndDayWithoutTheYear() {
        #expect(string(date(2026, 9, 10, 15, 42), now: date(2026, 9, 13, 15, 30)) == "Sep 10, 3:42 PM")
    }

    @Test func aPreviousYearShowsTheYear() {
        #expect(string(date(2025, 9, 10, 15, 42), now: date(2026, 9, 13, 15, 30)) == "Sep 10, 2025, 3:42 PM")
    }

    /// The time is the one part every case keeps.
    @Test func everyCaseCarriesTheTime() {
        let now = date(2026, 9, 13, 15, 30)
        let cases = [
            date(2026, 9, 13, 15, 42),
            date(2026, 9, 12, 15, 42),
            date(2026, 3, 2, 15, 42),
            date(2024, 3, 2, 15, 42)
        ]
        for moment in cases {
            #expect(string(moment, now: now).hasSuffix("3:42 PM"))
        }
    }

    /// A minute past midnight is still today, not a date.
    @Test func justAfterMidnightIsToday() {
        let now = date(2026, 9, 13, 15, 30)
        #expect(string(date(2026, 9, 13, 0, 1), now: now) == "12:01 AM")
    }

    /// The last minute of the previous day is yesterday, however few minutes
    /// separate the two.
    @Test func justBeforeMidnightIsYesterday() {
        #expect(string(date(2026, 9, 12, 23, 59), now: date(2026, 9, 13, 0, 1)) == "Yesterday, 11:59 PM")
    }

    /// Two days apart across New Year is a date with the year, since the
    /// comparison is calendar years rather than elapsed days.
    @Test func newYearsEveOfThePriorYearCarriesItsYear() {
        #expect(string(date(2025, 12, 31, 15, 42), now: date(2026, 1, 2)) == "Dec 31, 2025, 3:42 PM")
    }

    /// Yesterday wins over the year change: New Year's Day reading back at
    /// New Year's Eve still says the word.
    @Test func newYearsEveIsYesterdayOnNewYearsDay() {
        #expect(string(date(2025, 12, 31, 18, 0), now: date(2026, 1, 1, 9, 0)) == "Yesterday, 6:00 PM")
    }

    @Test func januaryFirstOfTheReadingYearDropsTheYear() {
        #expect(string(date(2026, 1, 1, 15, 42), now: date(2026, 12, 31)) == "Jan 1, 3:42 PM")
    }

    /// The day boundary is the calendar's, so a DST day shorter than 24 hours
    /// does not push a message into the wrong bucket.
    @Test func aDaylightSavingDayKeepsItsOwnBoundary() {
        let springForward = date(2026, 3, 8, 13, 0)
        #expect(string(springForward, now: date(2026, 3, 8, 23, 0)) == "1:00 PM")
        #expect(string(springForward, now: date(2026, 3, 9, 1, 0)) == "Yesterday, 1:00 PM")
    }
}

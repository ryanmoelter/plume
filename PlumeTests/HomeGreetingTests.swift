import Foundation
import Testing
@testable import Plume

/// Each greeting covers [start, end): morning 5–12, day 12–17, evening 17–21,
/// night 21–5.
struct HomeGreetingTests {
    @Test(arguments: [
        (4, HomeGreeting.night),
        (5, .morning),
        (11, .morning),
        (12, .day),
        (16, .day),
        (17, .evening),
        (20, .evening),
        (21, .night),
        (23, .night),
        (0, .night),
    ])
    func hourBoundaries(hour: Int, expected: HomeGreeting) {
        #expect(HomeGreeting(hour: hour) == expected)
    }

    @Test func readsTheHourFromTheCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 17, minute: 30)))
        #expect(HomeGreeting(date: date, calendar: calendar) == .evening)
    }
}

import Foundation
import GhosttyTheme
import SwiftUI
import Testing
@testable import Plume

/// Each greeting covers [start, end): morning 5–12, afternoon 12–17, evening 17–21,
/// night 21–5.
@MainActor
struct HomeGreetingTests {
    @Test(arguments: [
        (4, HomeGreeting.night),
        (5, .morning),
        (11, .morning),
        (12, .afternoon),
        (16, .afternoon),
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

    @Test func hoursTextFollowsTheHourMapping() {
        #expect(HomeGreeting.allCases.map(\.hoursText) == ["5 AM–12 PM", "12 PM–5 PM", "5 PM–9 PM", "9 PM–5 AM"])
    }

    @MainActor
    @Test func theEveningSunTakesTangerine() throws {
        let lum = try #require(GhosttyRuntime.bundledLumDefinitions)
        let lumColors = Palette(colorScheme: .dark, definitions: lum, usesExtendedPalette: true)
        #expect(HomeGreeting.evening.glyphRGB(in: lumColors) == HexRGB(hex: "f08e00"))
        #expect(HomeGreeting.morning.glyphRGB(in: lumColors) == HexRGB(hex: "f4cc25"))

        let tomorrowNight = GhosttyThemeDefinition(
            name: "Tomorrow Night",
            background: "1d1f21",
            foreground: "c5c8c6",
            palette: [
                0: "1d1f21", 1: "cc6666", 2: "b5bd68", 3: "f0c674", 4: "81a2be", 5: "b294bb", 6: "8abeb7", 7: "c5c8c6",
                8: "666666", 9: "d54e53", 10: "b9ca4a", 11: "e7c547", 12: "7aa6da", 13: "c397d8", 14: "70c0b1", 15: "eaeaea",
            ]
        )
        let colors = Palette(colorScheme: .dark, definitions: .init(light: nil, dark: tomorrowNight))
        #expect(HomeGreeting.morning.glyphRGB(in: colors) == HexRGB(hex: "e7c547"))
        #expect(HomeGreeting.evening.glyphRGB(in: colors) == HexRGB(hex: "f0c674"))
    }

    @Test func glyphColorPaintsTheSunOrMoonLayer() {
        #expect(HomeGreeting.allCases.map(\.glyphLayer) == [.secondary, .only, .secondary, .primary])
        #expect(HomeGreeting.allCases.map(\.drawsOtherGlyphLayer) == [false, false, false, true])
    }

    @Test func symbolsAreFilled() {
        #expect([HomeGreeting.morning, .afternoon, .evening, .night].map(\.symbolName)
            == ["sun.horizon.fill", "sun.max.fill", "sun.horizon.fill", "moon.stars.fill"])
    }
}

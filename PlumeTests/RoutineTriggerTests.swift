import Foundation
import Testing

@testable import Plume

/// When a routine is due: interval, weekly and once triggers, one catch-up
/// run however many slots were missed, and nothing while disabled.
struct RoutineTriggerTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func isDue(
        _ trigger: RoutineTrigger, enabled: Bool = true, lastRunAt: Date? = nil, scheduledFrom: Date, now: Date
    ) -> Bool {
        RoutineTrigger.isDue(
            trigger, isEnabled: enabled, lastRunAt: lastRunAt, scheduledFrom: scheduledFrom,
            now: now, calendar: Self.calendar
        )
    }

    @Test func intervalFirstRunsOneIntervalAfterScheduling() {
        let created = date(2026, 11, 23, 8)
        let trigger = RoutineTrigger.interval(hours: 3)
        #expect(!isDue(trigger, scheduledFrom: created, now: created))
        #expect(!isDue(trigger, scheduledFrom: created, now: date(2026, 11, 23, 10, 59)))
        #expect(isDue(trigger, scheduledFrom: created, now: date(2026, 11, 23, 11)))
    }

    @Test func intervalCountsFromTheLastRun() {
        let created = date(2026, 11, 23, 8)
        let ran = date(2026, 11, 23, 12)
        let trigger = RoutineTrigger.interval(hours: 3)
        #expect(!isDue(trigger, lastRunAt: ran, scheduledFrom: created, now: date(2026, 11, 23, 14)))
        #expect(isDue(trigger, lastRunAt: ran, scheduledFrom: created, now: date(2026, 11, 23, 15)))
    }

    @Test func weeklyFindsTheNextChosenDay() {
        // Nov 27, 2026 is a Friday.
        let trigger = RoutineTrigger.weekly(weekdays: [.monday], minuteOfDay: 9 * 60)
        let next = trigger.nextFireDate(after: date(2026, 11, 27, 10), calendar: Self.calendar)
        #expect(next == date(2026, 11, 30, 9))
    }

    @Test func weeklyFiresLaterTheSameDayButNotAtTheSameMinute() {
        let trigger = RoutineTrigger.weekly(weekdays: .everyDay, minuteOfDay: 9 * 60 + 30)
        #expect(trigger.nextFireDate(after: date(2026, 11, 23, 8), calendar: Self.calendar) == date(2026, 11, 23, 9, 30))
        #expect(trigger.nextFireDate(after: date(2026, 11, 23, 9, 30), calendar: Self.calendar) == date(2026, 11, 24, 9, 30))
    }

    @Test func weekdaysSkipTheWeekend() {
        let trigger = RoutineTrigger.weekly(weekdays: .weekdays, minuteOfDay: 9 * 60)
        // Friday 10:00 to Monday 9:00.
        #expect(trigger.nextFireDate(after: date(2026, 11, 27, 10), calendar: Self.calendar) == date(2026, 11, 30, 9))
    }

    @Test func weeklyKeepsLocalTimeAcrossDaylightSaving() {
        // US daylight saving ends Nov 1, 2026.
        let trigger = RoutineTrigger.weekly(weekdays: .everyDay, minuteOfDay: 9 * 60)
        #expect(trigger.nextFireDate(after: date(2026, 10, 31, 10), calendar: Self.calendar) == date(2026, 11, 1, 9))
        // And starts Mar 8, 2026, when 2:30 never happens.
        let early = RoutineTrigger.weekly(weekdays: .everyDay, minuteOfDay: 2 * 60 + 30)
        let skipped = early.nextFireDate(after: date(2026, 3, 7, 12), calendar: Self.calendar)
        #expect(skipped.map { Self.calendar.isDate($0, inSameDayAs: date(2026, 3, 8)) } == true)
    }

    @Test func weeklyWithNoDaysNeverFires() {
        let trigger = RoutineTrigger.weekly(weekdays: [], minuteOfDay: 9 * 60)
        #expect(trigger.nextFireDate(after: date(2026, 11, 23), calendar: Self.calendar) == nil)
        #expect(!isDue(trigger, scheduledFrom: date(2026, 1, 1), now: date(2026, 11, 23)))
    }

    @Test func missedSlotsCatchUpOnce() {
        let trigger = RoutineTrigger.weekly(weekdays: .everyDay, minuteOfDay: 9 * 60)
        let lastRun = date(2026, 11, 20, 9)
        let wake = date(2026, 11, 23, 14)
        #expect(isDue(trigger, lastRunAt: lastRun, scheduledFrom: date(2026, 11, 1), now: wake))
        // The catch-up run is stamped at wake time, which leaves nothing owed.
        #expect(!isDue(trigger, lastRunAt: wake, scheduledFrom: date(2026, 11, 1), now: date(2026, 11, 23, 14, 1)))
        #expect(isDue(trigger, lastRunAt: wake, scheduledFrom: date(2026, 11, 1), now: date(2026, 11, 24, 9)))
    }

    @Test func reenablingNeverFiresSlotsMissedWhileOff() {
        let trigger = RoutineTrigger.weekly(weekdays: .everyDay, minuteOfDay: 9 * 60)
        let reenabled = date(2026, 11, 23, 12)
        #expect(!isDue(trigger, lastRunAt: date(2026, 11, 1, 9), scheduledFrom: reenabled, now: date(2026, 11, 23, 13)))
        #expect(isDue(trigger, lastRunAt: date(2026, 11, 1, 9), scheduledFrom: reenabled, now: date(2026, 11, 24, 9)))
    }

    @Test func onceFiresAtItsDateAndOnlyOnce() {
        let at = date(2026, 11, 24, 9)
        let trigger = RoutineTrigger.once(at)
        let created = date(2026, 11, 23)
        #expect(!isDue(trigger, scheduledFrom: created, now: date(2026, 11, 24, 8, 59)))
        #expect(isDue(trigger, scheduledFrom: created, now: at))
        #expect(isDue(trigger, scheduledFrom: created, now: date(2026, 11, 30)))
        #expect(!isDue(trigger, lastRunAt: at, scheduledFrom: created, now: date(2026, 11, 30)))
    }

    @Test func onceInThePastNeverFires() {
        let trigger = RoutineTrigger.once(date(2026, 11, 1))
        #expect(!isDue(trigger, scheduledFrom: date(2026, 11, 23), now: date(2026, 11, 24)))
    }

    @Test func disabledIsNeverDue() {
        #expect(!isDue(.interval(hours: 1), enabled: false, scheduledFrom: date(2026, 1, 1), now: date(2026, 11, 23)))
    }

    @Test func summaries() {
        let calendar = Self.calendar
        #expect(RoutineTrigger.interval(hours: 1).summary(calendar: calendar) == "Every hour")
        #expect(RoutineTrigger.interval(hours: 6).summary(calendar: calendar) == "Every 6 hours")
        #expect(RoutineTrigger.weekly(weekdays: .weekdays, minuteOfDay: 9 * 60).summary(
            calendar: calendar, locale: Locale(identifier: "en_US")
        ).hasPrefix("Weekdays at 9:00"))
        #expect(RoutineTrigger.daysText([.monday, .wednesday], calendar: calendar) == "Mon, Wed")
        #expect(RoutineTrigger.daysText(.everyDay, calendar: calendar) == "Every day")
    }

    @Test func summaryClampsTheTimeLikeTheSchedule() {
        let calendar = Self.calendar
        let late = RoutineTrigger.timeText(minuteOfDay: 24 * 60 + 30, calendar: calendar)
        #expect(late == RoutineTrigger.timeText(minuteOfDay: 24 * 60 - 1, calendar: calendar))
        #expect(RoutineTrigger.timeText(minuteOfDay: -5, calendar: calendar) == RoutineTrigger.timeText(minuteOfDay: 0, calendar: calendar))
    }

    @Test func weekdayBitsMatchTheCalendar() {
        #expect(RoutineWeekdays(weekday: 1) == .sunday)
        #expect(RoutineWeekdays.weekdays.contains(weekday: 2))
        #expect(!RoutineWeekdays.weekdays.contains(weekday: 7))
        #expect(RoutineWeekdays.everyDay.rawValue == 0x7F)
    }
}

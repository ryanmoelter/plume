import Foundation

/// Days of the week as a bitmask, bit `n - 1` for `Calendar` weekday `n`
/// (1 is Sunday).
nonisolated struct RoutineWeekdays: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let sunday = RoutineWeekdays(weekday: 1)
    static let monday = RoutineWeekdays(weekday: 2)
    static let tuesday = RoutineWeekdays(weekday: 3)
    static let wednesday = RoutineWeekdays(weekday: 4)
    static let thursday = RoutineWeekdays(weekday: 5)
    static let friday = RoutineWeekdays(weekday: 6)
    static let saturday = RoutineWeekdays(weekday: 7)

    static let weekdays: RoutineWeekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let weekends: RoutineWeekdays = [.saturday, .sunday]
    static let everyDay: RoutineWeekdays = [.weekdays, .weekends]

    init(rawValue: Int) {
        self.rawValue = rawValue & 0x7F
    }

    init(weekday: Int) {
        self.init(rawValue: 1 << (weekday - 1))
    }

    func contains(weekday: Int) -> Bool {
        contains(RoutineWeekdays(weekday: weekday))
    }
}

nonisolated enum RoutineTriggerKind: String, CaseIterable, Sendable {
    case interval
    case weekly
    case once
}

/// When a routine runs. Pure, so the schedule is testable without a clock.
nonisolated enum RoutineTrigger: Equatable, Sendable {
    case interval(hours: Int)
    /// `minuteOfDay` is minutes after local midnight.
    case weekly(weekdays: RoutineWeekdays, minuteOfDay: Int)
    case once(Date)

    var kind: RoutineTriggerKind {
        switch self {
        case .interval: .interval
        case .weekly: .weekly
        case .once: .once
        }
    }

    /// The first slot strictly after `reference`. Nil when the trigger can
    /// never fire again: a weekly trigger with no days, or a `once` date
    /// already passed.
    func nextFireDate(after reference: Date, calendar: Calendar) -> Date? {
        switch self {
        case .interval(let hours):
            return reference.addingTimeInterval(TimeInterval(max(hours, 1)) * 3600)
        case .weekly(let weekdays, let minuteOfDay):
            guard !weekdays.isEmpty else { return nil }
            let minuteOfDay = Self.clamped(minuteOfDay: minuteOfDay)
            let hour = minuteOfDay / 60
            let minute = minuteOfDay % 60
            let startOfDay = calendar.startOfDay(for: reference)
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay),
                      weekdays.contains(weekday: calendar.component(.weekday, from: day)),
                      let slot = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                      slot > reference
                else { continue }
                return slot
            }
            return nil
        case .once(let date):
            return date > reference ? date : nil
        }
    }

    /// Whether a run is owed at `now`. Counts from the later of the last run
    /// and `scheduledFrom` — when the routine was created, enabled or
    /// rescheduled — so however many slots passed while the Mac was asleep
    /// or Plume was quit, the catch-up is one run, and turning a routine back
    /// on never fires the slots it missed while off.
    static func isDue(
        _ trigger: RoutineTrigger,
        isEnabled: Bool,
        lastRunAt: Date?,
        scheduledFrom: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard isEnabled else { return false }
        guard let next = nextFireDate(trigger, lastRunAt: lastRunAt, scheduledFrom: scheduledFrom, calendar: calendar)
        else { return false }
        return next <= now
    }

    static func nextFireDate(
        _ trigger: RoutineTrigger,
        lastRunAt: Date?,
        scheduledFrom: Date,
        calendar: Calendar
    ) -> Date? {
        let reference = max(lastRunAt ?? scheduledFrom, scheduledFrom)
        return trigger.nextFireDate(after: reference, calendar: calendar)
    }

    /// "Every 3 hours", "Weekdays at 9:00", "Once on Nov 24, 2026 at 9:00".
    func summary(calendar: Calendar, locale: Locale = .current) -> String {
        switch self {
        case .interval(let hours):
            return hours <= 1 ? "Every hour" : "Every \(hours) hours"
        case .weekly(let weekdays, let minuteOfDay):
            let time = Self.timeText(minuteOfDay: minuteOfDay, calendar: calendar, locale: locale)
            return "\(Self.daysText(weekdays, calendar: calendar, locale: locale)) at \(time)"
        case .once(let date):
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            style.locale = locale
            return "Once on \(date.formatted(style))"
        }
    }

    static func daysText(_ weekdays: RoutineWeekdays, calendar: Calendar, locale: Locale = .current) -> String {
        switch weekdays {
        case []: return "Never"
        case .everyDay: return "Every day"
        case .weekdays: return "Weekdays"
        case .weekends: return "Weekends"
        default:
            var symbols = calendar
            symbols.locale = locale
            let names = orderedWeekdays(calendar: calendar)
                .filter { weekdays.contains(weekday: $0) }
                .map { symbols.shortWeekdaySymbols[$0 - 1] }
            return names.joined(separator: ", ")
        }
    }

    /// Calendar weekdays starting from the calendar's first weekday.
    static func orderedWeekdays(calendar: Calendar) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    static func clamped(minuteOfDay: Int) -> Int {
        min(max(minuteOfDay, 0), 24 * 60 - 1)
    }

    static func timeText(minuteOfDay: Int, calendar: Calendar, locale: Locale = .current) -> String {
        let minuteOfDay = clamped(minuteOfDay: minuteOfDay)
        var components = DateComponents()
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        guard let date = calendar.date(from: components) else { return "" }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }
}

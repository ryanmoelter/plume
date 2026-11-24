import Foundation
import SwiftData

/// A prompt Plume starts as a new task on a schedule. `docs/routines.md` is
/// the reference.
@Model
final class Routine {
    var id: UUID = UUID()
    var name: String = ""
    var prompt: String = ""
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var orderIndex: Int = 0

    var folderPath: String = ""
    /// The repository directory holding `folderPath`, as a tab records it.
    /// Nil for a plain folder.
    var repoPath: String? = nil
    var runsInNewWorktree: Bool = false

    var providerID: String? = AgentProviderKind.claudeCode.rawValue
    var modelRaw: String? = nil
    var effortRaw: String? = nil
    var permissionModeRaw: String? = PermissionMode.auto.rawValue
    var codexCollaborationModeRaw: String = "default"

    /// A `RoutineTriggerKind` raw value.
    var triggerKindRaw: String = RoutineTriggerKind.weekly.rawValue
    var intervalHours: Int = 24
    var weeklyMinuteOfDay: Int = 9 * 60
    /// A `RoutineWeekdays` bitmask.
    var weekdaysRaw: Int = RoutineWeekdays.weekdays.rawValue
    var onceDate: Date? = nil
    /// When the routine was created, last enabled or last rescheduled. The
    /// schedule counts from here, so no slot before it is ever owed.
    var scheduledFrom: Date = Date()

    var notifiesOnFinish: Bool = false
    var lastRunAt: Date? = nil

    init(name: String = "", prompt: String = "", folderPath: String = "", orderIndex: Int = 0, now: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.prompt = prompt
        self.folderPath = folderPath
        self.orderIndex = orderIndex
        self.createdAt = now
        self.scheduledFrom = now
    }

    var triggerKind: RoutineTriggerKind {
        get { RoutineTriggerKind(rawValue: triggerKindRaw) ?? .weekly }
        set { triggerKindRaw = newValue.rawValue }
    }

    var weekdays: RoutineWeekdays {
        get { RoutineWeekdays(rawValue: weekdaysRaw) }
        set { weekdaysRaw = newValue.rawValue }
    }

    /// A `once` routine with no date reads as one that already ran.
    var trigger: RoutineTrigger {
        get {
            switch triggerKind {
            case .interval: .interval(hours: max(intervalHours, 1))
            case .weekly: .weekly(weekdays: weekdays, minuteOfDay: weeklyMinuteOfDay)
            case .once: .once(onceDate ?? .distantPast)
            }
        }
        set {
            triggerKind = newValue.kind
            switch newValue {
            case .interval(let hours): intervalHours = max(hours, 1)
            case .weekly(let days, let minuteOfDay):
                weekdays = days
                weeklyMinuteOfDay = minuteOfDay
            case .once(let date): onceDate = date
            }
        }
    }

    var provider: AgentProviderKind {
        get { providerID.flatMap(AgentProviderKind.init(rawValue:)) ?? .claudeCode }
        set { providerID = newValue.rawValue }
    }

    var launchChoices: TabLaunchChoices {
        get {
            TabLaunchChoices(
                providerID: providerID,
                transportRaw: AgentTransport.headless.rawValue,
                modelRaw: modelRaw,
                isModelUserChosen: modelRaw != nil,
                effortRaw: effortRaw,
                isEffortUserChosen: effortRaw != nil,
                permissionModeRaw: permissionModeRaw,
                codexCollaborationModeRaw: codexCollaborationModeRaw
            )
        }
        set {
            providerID = newValue.providerID
            modelRaw = newValue.modelRaw
            effortRaw = newValue.effortRaw
            permissionModeRaw = newValue.permissionModeRaw
            codexCollaborationModeRaw = newValue.codexCollaborationModeRaw
        }
    }

    func setEnabled(_ enabled: Bool, now: Date = Date()) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled { scheduledFrom = now }
    }

    func nextFireDate(calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        return RoutineTrigger.nextFireDate(trigger, lastRunAt: lastRunAt, scheduledFrom: scheduledFrom, calendar: calendar)
    }

    func isDue(now: Date, calendar: Calendar = .current) -> Bool {
        RoutineTrigger.isDue(
            trigger, isEnabled: isEnabled, lastRunAt: lastRunAt, scheduledFrom: scheduledFrom,
            now: now, calendar: calendar
        )
    }
}

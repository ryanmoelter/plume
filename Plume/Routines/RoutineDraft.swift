import Foundation

/// A routine's fields while the editor has them, written back only on save.
nonisolated struct RoutineDraft: Equatable {
    var name = ""
    var prompt = ""
    var folderPath = ""
    var repoPath: String?
    var runsInNewWorktree = false
    var triggerKind: RoutineTriggerKind = .weekly
    var intervalHours = 24
    var weekdays: RoutineWeekdays = .weekdays
    var minuteOfDay = 9 * 60
    var onceDate = Date().addingTimeInterval(3600)
    var notifiesOnFinish = false
    var choices = TabLaunchChoices(
        providerID: AgentProviderKind.claudeCode.rawValue,
        transportRaw: AgentTransport.headless.rawValue,
        permissionModeRaw: PermissionMode.auto.rawValue
    )

    var trigger: RoutineTrigger {
        switch triggerKind {
        case .interval: .interval(hours: intervalHours)
        case .weekly: .weekly(weekdays: weekdays, minuteOfDay: minuteOfDay)
        case .once: .once(onceDate)
        }
    }

    /// Nil when the draft can be saved, else what's missing.
    func problem(now: Date) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name the routine." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a prompt." }
        if folderPath.isEmpty { return "Choose a folder." }
        switch triggerKind {
        case .interval where intervalHours < 1: return "Run at least every hour."
        case .weekly where weekdays.isEmpty: return "Choose at least one day."
        case .once where onceDate <= now: return "Choose a time in the future."
        default: return nil
        }
    }
}

extension RoutineDraft {
    init(_ routine: Routine) {
        self.init(
            name: routine.name,
            prompt: routine.prompt,
            folderPath: routine.folderPath,
            repoPath: routine.repoPath,
            runsInNewWorktree: routine.runsInNewWorktree,
            triggerKind: routine.triggerKind,
            intervalHours: max(routine.intervalHours, 1),
            weekdays: routine.weekdays,
            minuteOfDay: routine.weeklyMinuteOfDay,
            onceDate: routine.onceDate ?? Date().addingTimeInterval(3600),
            notifiesOnFinish: routine.notifiesOnFinish,
            choices: routine.launchChoices
        )
    }

    /// A changed schedule counts from `now`, so editing never fires a slot
    /// the old schedule missed.
    func apply(to routine: Routine, now: Date = Date()) {
        let rescheduled = routine.trigger != trigger
        routine.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        routine.prompt = prompt
        routine.folderPath = folderPath
        routine.repoPath = repoPath
        routine.runsInNewWorktree = runsInNewWorktree && repoPath != nil
        routine.trigger = trigger
        routine.notifiesOnFinish = notifiesOnFinish
        routine.launchChoices = choices
        if rescheduled { routine.scheduledFrom = now }
    }
}

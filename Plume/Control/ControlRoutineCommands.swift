#if DEBUG
import Foundation
import SwiftData

/// Every field of a routine, so a driver can make one without the editor.
/// `trigger` is `interval`, `weekly` or `once`. `weekdays` takes short names
/// (`mon`) or `weekdays`, `weekends`, `everyday`; `time` is `HH:mm`; `date`
/// is ISO 8601.
nonisolated struct RoutineCreateParams: Decodable, Equatable {
    var name: String?
    var prompt: String?
    var folder: String?
    var newWorktree: Bool?
    var provider: String?
    var model: String?
    var effort: String?
    var permissionMode: String?
    var trigger: String?
    var intervalHours: Int?
    var weekdays: [String]?
    var time: String?
    var date: String?
    var notifiesOnFinish: Bool?
    var enabled: Bool?
}

nonisolated struct RoutineRunParams: Decodable, Equatable {
    var routine: String?
}

/// `now` is ISO 8601; without it, the real clock.
nonisolated struct RoutineTickParams: Decodable, Equatable {
    var now: String?
}

nonisolated struct ControlRoutineInfo: Encodable, Equatable {
    let id: UUID
    let name: String
    let enabled: Bool
    let trigger: String
    let schedule: String
    let folder: String
    let repoPath: String?
    let newWorktree: Bool
    let provider: String
    let permissionMode: String?
    let notifiesOnFinish: Bool
    let nextRunAt: String?
    let lastRunAt: String?
    let lastError: String?
    let lastTaskID: UUID?
    let starting: Bool
}

nonisolated struct RoutineListResult: Encodable, Equatable {
    let routines: [ControlRoutineInfo]
}

nonisolated struct RoutineRunResult: Encodable, Equatable {
    let routine: ControlRoutineInfo
    let taskID: UUID?
    let tabID: UUID?
}

nonisolated struct RoutineTickResult: Encodable, Equatable {
    let now: String
    /// The routines this tick started. They finish starting after the reply.
    let started: [UUID]
}

@MainActor
enum ControlRoutineCommands {
    static func list(scheduler: RoutineScheduler = .shared) throws -> RoutineListResult {
        RoutineListResult(routines: RoutineCommands.routines(in: try context(scheduler)).map { info($0, scheduler) })
    }

    static func create(_ params: RoutineCreateParams, scheduler: RoutineScheduler = .shared) async throws -> ControlRoutineInfo {
        let context = try context(scheduler)
        guard let name = params.name, !name.isEmpty else { throw ControlError.badParams("routines.create needs name") }
        guard let prompt = params.prompt, !prompt.isEmpty else { throw ControlError.badParams("routines.create needs prompt") }
        guard let folder = params.folder.map({ ($0 as NSString).expandingTildeInPath }) else {
            throw ControlError.badParams("routines.create needs folder")
        }
        var draft = RoutineDraft(name: name, prompt: prompt, folderPath: folder)
        draft.repoPath = await Task.detached {
            ProjectRoot.containing(folder).map(ProjectRoot.repositoryDirectory(forRoot:))
        }.value
        draft.runsInNewWorktree = params.newWorktree ?? false
        if let provider = params.provider {
            guard let kind = AgentProviderKind(rawValue: provider) else {
                throw ControlError.badParams("provider is claude-code or codex")
            }
            draft.choices.providerID = kind.rawValue
            if kind == .codex, params.permissionMode == nil { draft.choices.permissionModeRaw = nil }
        }
        if let model = params.model { draft.choices.modelRaw = model }
        if let effort = params.effort { draft.choices.effortRaw = effort }
        if let mode = params.permissionMode { draft.choices.permissionModeRaw = mode }
        if let trigger = params.trigger {
            guard let kind = RoutineTriggerKind(rawValue: trigger) else {
                throw ControlError.badParams("trigger is interval, weekly or once")
            }
            draft.triggerKind = kind
        }
        if let hours = params.intervalHours { draft.intervalHours = hours }
        if let days = params.weekdays { draft.weekdays = try weekdays(days) }
        if let time = params.time {
            guard let minutes = RoutineEditor.minuteOfDay(parsing: time) else { throw ControlError.badParams("time is HH:mm") }
            draft.minuteOfDay = minutes
        }
        if let date = params.date { draft.onceDate = try parseDate(date) }
        draft.notifiesOnFinish = params.notifiesOnFinish ?? false
        if let problem = draft.problem(now: scheduler.now()) { throw ControlError.badParams(problem) }

        let existing = RoutineCommands.routines(in: context)
        let routine = Routine(orderIndex: (existing.map(\.orderIndex).max() ?? -1) + 1, now: scheduler.now())
        context.insert(routine)
        draft.apply(to: routine, now: scheduler.now())
        if params.enabled == false { routine.isEnabled = false }
        return info(routine, scheduler)
    }

    static func run(_ params: RoutineRunParams, scheduler: RoutineScheduler = .shared) async throws -> RoutineRunResult {
        guard let query = params.routine else { throw ControlError.badParams("routines.run needs routine") }
        let routine = try RoutineCommands.routine(query, in: try context(scheduler))
        guard let lastRun = await scheduler.runNowAndWait(routine) else {
            throw ControlError.badParams("\(routine.name) is already starting")
        }
        return RoutineRunResult(routine: info(routine, scheduler), taskID: lastRun.taskID, tabID: lastRun.tabID)
    }

    static func tick(_ params: RoutineTickParams, scheduler: RoutineScheduler = .shared) throws -> RoutineTickResult {
        _ = try context(scheduler)
        let now = try params.now.map(parseDate) ?? scheduler.now()
        return RoutineTickResult(now: now.ISO8601Format(), started: scheduler.tick(now: now))
    }

    private static func context(_ scheduler: RoutineScheduler) throws -> ModelContext {
        guard let context = scheduler.readyContext() else { throw ControlError.noWindow }
        return context
    }

    private static func info(_ routine: Routine, _ scheduler: RoutineScheduler) -> ControlRoutineInfo {
        let lastRun = scheduler.lastRuns[routine.id]
        return ControlRoutineInfo(
            id: routine.id,
            name: routine.name,
            enabled: routine.isEnabled,
            trigger: routine.triggerKind.rawValue,
            schedule: routine.trigger.summary(calendar: scheduler.calendar()),
            folder: routine.folderPath,
            repoPath: routine.repoPath,
            newWorktree: routine.runsInNewWorktree,
            provider: routine.provider.rawValue,
            permissionMode: routine.permissionModeRaw,
            notifiesOnFinish: routine.notifiesOnFinish,
            nextRunAt: routine.nextFireDate(calendar: scheduler.calendar())?.ISO8601Format(),
            lastRunAt: routine.lastRunAt?.ISO8601Format(),
            lastError: lastRun?.error,
            lastTaskID: lastRun?.taskID,
            starting: scheduler.isStarting(routine.id)
        )
    }

    private static func parseDate(_ text: String) throws -> Date {
        guard let date = try? Date(text, strategy: .iso8601) else {
            throw ControlError.badParams("'\(text)' is not an ISO 8601 date")
        }
        return date
    }

    private static func weekdays(_ names: [String]) throws -> RoutineWeekdays {
        let short = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var days: RoutineWeekdays = []
        for name in names.map({ $0.lowercased() }) {
            switch name {
            case "weekdays": days.formUnion(.weekdays)
            case "weekends": days.formUnion(.weekends)
            case "everyday", "every day", "daily": days.formUnion(.everyDay)
            default:
                guard let index = short.firstIndex(where: { name.hasPrefix($0) }) else {
                    throw ControlError.badParams("unknown weekday '\(name)'")
                }
                days.insert(RoutineWeekdays(weekday: index + 1))
            }
        }
        return days
    }
}
#endif

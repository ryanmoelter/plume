import Foundation
import SwiftData

/// What `plume routine` and the control server's `routines.*` share: listing
/// routines and naming one.
@MainActor
enum RoutineCommands {
    nonisolated enum LookupError: Error, Equatable, LocalizedError {
        case noWindow
        case notFound(String)
        case ambiguous(String, [String])

        var errorDescription: String? {
            switch self {
            case .noWindow: "no Plume window is open"
            case .notFound(let query): "no routine matches '\(query)'"
            case .ambiguous(let query, let names):
                "'\(query)' matches \(names.count) routines: \(names.joined(separator: ", "))"
            }
        }
    }

    static func routines(in context: ModelContext) -> [Routine] {
        (try? context.fetch(FetchDescriptor<Routine>(sortBy: [SortDescriptor(\.orderIndex)]))) ?? []
    }

    /// An ID, then an exact name ignoring case, then a unique part of a name.
    nonisolated static func match(_ query: String, among routines: [(id: UUID, name: String)]) throws -> UUID {
        if let id = UUID(uuidString: query), routines.contains(where: { $0.id == id }) { return id }
        let exact = routines.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        if exact.count == 1 { return exact[0].id }
        let partial = exact.isEmpty ? routines.filter { $0.name.localizedCaseInsensitiveContains(query) } : exact
        guard let first = partial.first else { throw LookupError.notFound(query) }
        guard partial.count == 1 else { throw LookupError.ambiguous(query, partial.map(\.name)) }
        return first.id
    }

    static func routine(_ query: String, in context: ModelContext) throws -> Routine {
        let all = routines(in: context)
        let id = try match(query, among: all.map { ($0.id, $0.name) })
        guard let routine = all.first(where: { $0.id == id }) else { throw LookupError.notFound(query) }
        return routine
    }

    static func info(
        _ routine: Routine, scheduler: RoutineScheduler = .shared, calendar: Calendar = .current
    ) -> CLIRoutineInfo {
        let lastRun = scheduler.lastRuns[routine.id]
        return CLIRoutineInfo(
            id: routine.id,
            name: routine.name,
            isEnabled: routine.isEnabled,
            schedule: routine.trigger.summary(calendar: calendar),
            nextRunAt: routine.nextFireDate(calendar: calendar),
            lastRunAt: routine.lastRunAt,
            lastError: lastRun?.error,
            lastTaskID: lastRun?.taskID
        )
    }

    static func handle(_ request: CLIRequest, scheduler: RoutineScheduler = .shared) async -> CLIResponse {
        guard let context = scheduler.context() else { return .failure(LookupError.noWindow.localizedDescription) }
        switch request {
        case .listRoutines:
            var response = CLIResponse.success
            response.routines = routines(in: context).map { info($0, scheduler: scheduler) }
            return response
        case .runRoutine(let params):
            do {
                let routine = try routine(params.routine, in: context)
                guard let lastRun = await scheduler.runNowAndWait(routine) else {
                    return .failure("\(routine.name) is already starting")
                }
                if let error = lastRun.error { return .failure(error) }
                var response = CLIResponse.success
                response.taskID = lastRun.taskID
                response.tabID = lastRun.tabID
                response.routine = info(routine, scheduler: scheduler)
                return response
            } catch {
                return .failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        default:
            return .failure("not a routine command")
        }
    }
}

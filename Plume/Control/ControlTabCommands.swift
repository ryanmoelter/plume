#if DEBUG
import Foundation
import SwiftData

/// Names a tab by `tabID`, or by a substring of its title.
nonisolated struct TabMoveParams: Decodable, Equatable {
    var tabID: UUID?
    var label: String?
    /// A task ID, or a substring of the task's title.
    var toTask: String?
}

nonisolated struct TabTaskResult: Encodable, Equatable {
    let tabID: UUID
    let taskID: UUID
}

/// `tab.move` and `tab.split`: moving a tab between tasks takes a drag the
/// control server cannot start, so these call `TaskStore` directly.
@MainActor
enum ControlTabCommands {
    static func move(_ params: TabMoveParams, in context: ModelContext) throws -> TabTaskResult {
        let tasks = try liveTasks(in: context)
        let tab = try tab(params, among: tasks)
        guard let toTask = params.toTask else { throw ControlError.badParams("tab.move needs toTask") }
        let destination = try task(toTask, among: tasks)
        guard tab.task?.id != destination.id else { throw ControlError.badParams("the tab is already in that task") }
        TaskStore.moveTab(tab, to: destination)
        return TabTaskResult(tabID: tab.id, taskID: destination.id)
    }

    static func split(_ params: TabMoveParams, in context: ModelContext) throws -> TabTaskResult {
        let tasks = try liveTasks(in: context)
        let tab = try tab(params, among: tasks)
        let task = TaskStore.splitTabIntoNewTask(tab, in: context, siblings: tasks.filter { $0.group == nil })
        return TabTaskResult(tabID: tab.id, taskID: task.id)
    }

    /// The frontmost main window's store, which every window shares.
    static func frontmostContext() throws -> ModelContext {
        guard let context = CLICommandHandler.shared.frontmostWindow?.context else { throw ControlError.noWindow }
        return context
    }

    static func liveTasks(in context: ModelContext) throws -> [WorkTask] {
        try context.fetch(FetchDescriptor<WorkTask>()).filter { !$0.isArchived }
    }

    private static func tab(_ params: TabMoveParams, among tasks: [WorkTask]) throws -> TaskTab {
        let tabs = tasks.flatMap(\.liveTabs)
        if let id = params.tabID {
            guard let tab = tabs.first(where: { $0.id == id }) else { throw ControlError.notFound("tab \(id)") }
            return tab
        }
        guard let label = params.label else { throw ControlError.badParams("name the tab with tabID or label") }
        let matches = tabs.filter { $0.displayTitle.localizedCaseInsensitiveContains(label) }
        guard matches.count < 2 else { throw ControlError.ambiguous("tab \"\(label)\"", count: matches.count) }
        guard let tab = matches.first else { throw ControlError.notFound("tab \"\(label)\"") }
        return tab
    }

    static func task(_ name: String, among tasks: [WorkTask]) throws -> WorkTask {
        if let id = UUID(uuidString: name) {
            guard let task = tasks.first(where: { $0.id == id }) else { throw ControlError.notFound("task \(id)") }
            return task
        }
        let matches = tasks.filter { TitleStore.shared.displayTitle(for: $0).localizedCaseInsensitiveContains(name) }
        guard matches.count < 2 else { throw ControlError.ambiguous("task \"\(name)\"", count: matches.count) }
        guard let task = matches.first else { throw ControlError.notFound("task \"\(name)\"") }
        return task
    }
}
#endif

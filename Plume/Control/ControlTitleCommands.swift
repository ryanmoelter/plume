#if DEBUG
import Foundation
import SwiftData

/// `task` matches a task's ID or title, as `sidebar.reveal` does.
nonisolated struct TaskRenameParams: Decodable, Equatable {
    var task: String?
    var title: String?
}

/// Names a tab by `tabID`, or by a substring of its title.
nonisolated struct TabTitleParams: Decodable, Equatable {
    var tabID: UUID?
    var label: String?
    var title: String?
}

nonisolated struct TitleResult: Encodable, Equatable {
    let taskID: UUID
    let tabID: UUID?
    let title: String
}

/// `task.rename` and `tab.title`: change a title in place, so a driver can
/// watch the sidebar's text wipe without a popover or a running agent.
@MainActor
enum ControlTitleCommands {
    static func renameTask(_ params: TaskRenameParams, in context: ModelContext) throws -> TitleResult {
        guard let name = params.task else { throw ControlError.badParams("task.rename needs task") }
        guard let title = params.title else { throw ControlError.badParams("task.rename needs title") }
        let task = try ControlTabCommands.task(name, among: try ControlTabCommands.liveTasks(in: context))
        task.title = title
        return TitleResult(taskID: task.id, tabID: nil, title: TitleStore.shared.displayTitle(for: task))
    }

    /// Sets the title at the highest source rank, as `/rename` would, so it
    /// always replaces the one shown.
    static func setTabTitle(_ params: TabTitleParams, in context: ModelContext) throws -> TitleResult {
        guard let title = params.title else { throw ControlError.badParams("tab.title needs title") }
        let tasks = try ControlTabCommands.liveTasks(in: context)
        let tab = try ControlTabCommands.tab(id: params.tabID, label: params.label, among: tasks)
        guard let task = tab.task else { throw ControlError.notFound("the task of tab \(tab.id)") }
        TitleStore.shared.setTitle(title, forTab: tab.id, source: .custom)
        return TitleResult(taskID: task.id, tabID: tab.id, title: TitleStore.shared.displayTitle(forTab: tab) ?? title)
    }
}
#endif

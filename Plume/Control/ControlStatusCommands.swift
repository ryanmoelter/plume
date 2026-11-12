#if DEBUG
import Foundation
import SwiftData

/// Names a tab by `tabID`, or by a substring of its title. `status` is a
/// `TaskStatus` raw value; `unread`, when given, overrides the mark the new
/// status would leave.
nonisolated struct TabStatusParams: Decodable, Equatable {
    var tabID: UUID?
    var label: String?
    var status: String?
    var unread: Bool?
}

nonisolated struct TabStatusResult: Encodable, Equatable {
    let tabID: UUID
    let taskID: UUID
    let status: String
    let unread: Bool
}

/// `tab.status`: drives a tab's status the way an agent event does, through
/// `StatusEngine`, so `UnreadStore` and the sidebar react as they would live.
@MainActor
enum ControlStatusCommands {
    static func setStatus(
        _ params: TabStatusParams,
        in context: ModelContext,
        engine: StatusEngine = .shared,
        unreadStore: UnreadStore = .shared
    ) throws -> TabStatusResult {
        guard let raw = params.status else { throw ControlError.badParams("tab.status needs status") }
        guard let status = TaskStatus(rawValue: raw) else {
            let known = TaskStatus.allCases.map(\.rawValue).joined(separator: ", ")
            throw ControlError.badParams("unknown status \"\(raw)\"; expected one of \(known)")
        }
        let tasks = try ControlTabCommands.liveTasks(in: context)
        let tab = try ControlTabCommands.tab(id: params.tabID, label: params.label, among: tasks)
        guard let task = tab.task else { throw ControlError.notFound("the task of tab \(tab.id)") }

        // A driven status is the app's doing, not the user's, so it sends no system notification.
        engine.setStatus(status, taskID: task.id, tabID: tab.id, notifiable: false)
        switch params.unread {
        case true?: unreadStore.markUnread([tab.id])
        case false?: unreadStore.markRead([tab.id])
        case nil: break
        }
        return TabStatusResult(
            tabID: tab.id,
            taskID: task.id,
            status: engine.status(forTab: tab.id).rawValue,
            unread: unreadStore.isUnread(tabID: tab.id)
        )
    }
}
#endif

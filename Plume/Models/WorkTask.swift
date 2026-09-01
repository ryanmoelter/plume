import Foundation
import SwiftData

@Model
final class WorkTask {
    var id: UUID = UUID()
    var title: String = ""
    var orderIndex: Int = 0
    var createdAt: Date = Date()

    /// nil means the task lives in the "Ungrouped" section.
    var group: TaskGroup?

    var workspaceKindRaw: String = WorkspaceKind.unset.rawValue
    var workingDirectoryPath: String?
    var repoPath: String?
    var branchName: String?

    /// Snapshot so the sidebar can show badges before any agent process is live.
    var lastStatusRaw: String = TaskStatus.unset.rawValue
    var isArchived: Bool = false

    /// Reserved for PR/Linear integration payloads.
    var integrationsData: Data?

    @Relationship(deleteRule: .cascade, inverse: \TaskTab.task)
    var tabs: [TaskTab] = []
    var selectedTabID: UUID?
    /// Which agent tab's title stands in for the task in the sidebar, so
    /// dipping into a terminal tab doesn't relabel the row.
    var lastFocusedAgentTabID: UUID?

    init(title: String, orderIndex: Int, group: TaskGroup? = nil) {
        self.id = UUID()
        self.title = title
        self.orderIndex = orderIndex
        self.createdAt = Date()
        self.group = group
    }

    var workspaceKind: WorkspaceKind {
        get { WorkspaceKind(rawValue: workspaceKindRaw) ?? .unset }
        set { workspaceKindRaw = newValue.rawValue }
    }

    var lastStatus: TaskStatus {
        get { TaskStatus(rawValue: lastStatusRaw) ?? .unset }
        set { lastStatusRaw = newValue.rawValue }
    }

    var orderedTabs: [TaskTab] {
        tabs.sorted { $0.orderIndex < $1.orderIndex }
    }
}

import Foundation
import SwiftData

/// Copies each task's workspace onto its tabs, which now own one each. Runs
/// at launch and touches only tabs not yet migrated, so a second run changes
/// nothing.
///
/// A task left with tabs then has its own copy cleared, since it would
/// otherwise read as `heldWorkspace`. A task with no tabs keeps it as that.
enum TabWorkspaceMigration {
    static func run(in context: ModelContext) throws {
        let tabs = try context.fetch(FetchDescriptor<TaskTab>()).filter { !$0.isWorkspaceMigrated }
        guard !tabs.isEmpty else { return }
        tabs.forEach(migrate)
        for task in Set(tabs.compactMap(\.task)) where !task.tabs.isEmpty {
            task.heldWorkspace = TabWorkspace()
        }
        try context.save()
    }

    /// Fills only what the tab lacks: a folder the tab already reported is
    /// where it really is, so the task's never replaces it.
    static func migrate(_ tab: TaskTab) {
        defer { tab.isWorkspaceMigrated = true }
        guard let task = tab.task else { return }
        if tab.workingDirectoryPath == nil { tab.workingDirectoryPath = task.workingDirectoryPath }
        if tab.repoPath == nil { tab.repoPath = task.repoPath }
        if tab.branchName == nil { tab.branchName = task.branchName }
        if tab.workspaceKind == .unset { tab.workspaceKindRaw = task.workspaceKindRaw }
    }
}

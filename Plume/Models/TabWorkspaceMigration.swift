import Foundation
import SwiftData

/// Moves an older build's task workspace onto the task's tabs, which now own
/// one each. A task whose workspace was a worktree also records it in
/// `ownedWorktrees`. The task's fields are cleared once read, and only tabs
/// not yet migrated are touched, so a second run changes nothing.
enum TabWorkspaceMigration {
    static func run(in context: ModelContext) throws {
        let tabs = try context.fetch(FetchDescriptor<TaskTab>()).filter { !$0.isWorkspaceMigrated }
        tabs.forEach(migrate)
        let legacyTasks = try context.fetch(FetchDescriptor<WorkTask>()).filter(hasLegacyWorkspace)
        legacyTasks.forEach(migrate)
        guard !tabs.isEmpty || !legacyTasks.isEmpty else { return }
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

    private static func hasLegacyWorkspace(_ task: WorkTask) -> Bool {
        task.workspaceKindRaw != WorkspaceKind.unset.rawValue
            || task.workingDirectoryPath != nil || task.repoPath != nil || task.branchName != nil
    }

    /// An older task could save a subfolder of its worktree. Found by `.git`
    /// rather than by git itself, so launch never waits on a process; a
    /// folder that no longer exists is kept as saved.
    nonisolated static func checkoutRoot(containing path: String) -> String {
        let files = FileManager.default
        guard files.fileExists(atPath: path) else { return path }
        var folder = URL(fileURLWithPath: path).standardizedFileURL
        while folder.path != "/" {
            if files.fileExists(atPath: folder.appending(path: ".git").path) { return folder.path }
            folder.deleteLastPathComponent()
        }
        return path
    }

    private static func migrate(_ task: WorkTask) {
        if task.workspaceKindRaw == WorkspaceKind.worktree.rawValue,
           let path = task.workingDirectoryPath, let repoPath = task.repoPath {
            task.recordOwnedWorktree(OwnedWorktree(path: checkoutRoot(containing: path), repoPath: repoPath, branch: task.branchName))
        }
        task.workspaceKindRaw = WorkspaceKind.unset.rawValue
        task.workingDirectoryPath = nil
        task.repoPath = nil
        task.branchName = nil
    }
}

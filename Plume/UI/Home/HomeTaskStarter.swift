import Foundation
import SwiftData

/// Turns a `HomeTaskPlan` into a task with a running agent: the same task ⌘N
/// creates, given its workspace and the Home composer's launch choices, then
/// launched with the plan's message the way a never-started tab sends its
/// first one.
@MainActor
enum HomeTaskStarter {
    static func start(
        _ plan: HomeTaskPlan,
        in context: ModelContext,
        groups: [TaskGroup],
        tasks: [WorkTask]
    ) async throws -> WorkTask {
        let directory: String
        switch plan.workspace {
        case .directory(let path, _):
            directory = path
        case .newWorktree(let repository, let branch):
            directory = try await GitService.shared.createWorktree(
                repository: repository,
                branch: branch,
                basePath: AppSettings.shared.worktreeBasePath
            )
        }
        let task = createTask(for: plan, directory: directory, in: context, groups: groups, tasks: tasks)
        if let tab = task.orderedTabs.first {
            AgentLauncher.launch(blocks: plan.blocks, task: task, tab: tab)
        }
        return task
    }

    /// `directory` is the plan's folder, or the worktree just created for it.
    static func createTask(
        for plan: HomeTaskPlan,
        directory: String,
        in context: ModelContext,
        groups: [TaskGroup],
        tasks: [WorkTask],
        recentFolders: UserDefaults = .standard
    ) -> WorkTask {
        let group = groups.first { $0.id == plan.groupID }
        let siblings = tasks.filter { $0.group?.id == group?.id }
        let task = TaskStore.createTask(in: context, group: group, siblings: siblings)
        if let choices = plan.choices, let tab = task.orderedTabs.first {
            choices.apply(to: tab)
        }
        task.workingDirectoryPath = directory
        switch plan.workspace {
        case .directory(_, let repoPath):
            task.repoPath = repoPath
            task.workspaceKind = .directory
            RecentFolders.remember(directory, in: recentFolders)
        case .newWorktree(let repository, let branch):
            task.repoPath = repository
            task.branchName = branch
            task.workspaceKind = .worktree
            RecentFolders.remember(repository, in: recentFolders)
        }
        return task
    }
}

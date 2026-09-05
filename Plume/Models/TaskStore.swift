import Foundation
import SwiftData
import SwiftUI // Array.move(fromOffsets:toOffset:)

/// Create/reorder/delete operations over the task tree.
///
/// Ordering is stored as a dense `orderIndex` per section, rewritten on every
/// move so drag-reorder and cross-group moves share one code path.
enum TaskStore {
    // MARK: - Create

    /// `defaultsToRecentFolder` seeds the workspace from the last folder used,
    /// so a new task is ready to run in the place you were already working.
    /// Off by default: it reads `UserDefaults` and shells out to `git`, which
    /// callers that just want a bare task shouldn't pay for.
    @discardableResult
    static func createTask(
        in context: ModelContext,
        title: String = "",
        group: TaskGroup? = nil,
        siblings: [WorkTask],
        defaultsToRecentFolder: Bool = false
    ) -> WorkTask {
        let task = WorkTask(title: title, orderIndex: nextIndex(after: siblings), group: group)
        if defaultsToRecentFolder, let folder = RecentFolders.mostRecent {
            task.workingDirectoryPath = folder
            task.workspaceKind = .directory
            // Filled in once `git` answers: creating a task must not wait on
            // a subprocess, and nothing reads `repoPath` before then.
            Task { task.repoPath = await GitService.shared.repositoryRoot(containing: folder) }
        }
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        tab.transport = AppSettings.shared.defaultAgentTransport
        context.insert(task)
        context.insert(tab)
        task.tabs = [tab]
        selectTab(tab, in: task)
        return task
    }

    @discardableResult
    static func createGroup(
        in context: ModelContext,
        name: String = "New Group",
        existing: [TaskGroup]
    ) -> TaskGroup {
        let group = TaskGroup(name: name, orderIndex: nextIndex(after: existing))
        context.insert(group)
        return group
    }

    @discardableResult
    static func addTab(to task: WorkTask, kind: TabKind, in context: ModelContext) -> TaskTab {
        let tab = TaskTab(kind: kind, orderIndex: nextIndex(after: task.tabs), task: task)
        if kind == .agent {
            tab.transport = AppSettings.shared.defaultAgentTransport
        }
        context.insert(tab)
        task.tabs.append(tab)
        selectTab(tab, in: task)
        return tab
    }

    // MARK: - Selection

    /// The one place selection changes, so `lastFocusedAgentTabID` cannot
    /// drift out of step with it.
    static func selectTab(_ tab: TaskTab, in task: WorkTask) {
        task.selectedTabID = tab.id
        if tab.kind == .agent {
            task.lastFocusedAgentTabID = tab.id
        }
    }

    // MARK: - Delete

    /// The cascade delete removes the tabs, but their terminals are held
    /// outside SwiftData and have to be closed explicitly.
    static func delete(_ task: WorkTask, in context: ModelContext) {
        for tab in task.tabs {
            SurfaceManager.shared.closeSession(for: tab.id)
            HeadlessSessionManager.shared.closeSession(for: tab.id)
            DraftStore.shared.forget(tabID: tab.id)
            BellStore.shared.forget(tabID: tab.id)
            TranscriptStore.shared.stopWatching(tabID: tab.id)
            UntrustedDirectoryStore.shared.clear(tabID: tab.id)
        }
        context.delete(task)
    }

    /// Deleting a group would cascade to its tasks, so move them to Ungrouped first.
    static func deleteGroup(_ group: TaskGroup, in context: ModelContext, keepingTasks: Bool = true) {
        if keepingTasks {
            for task in group.tasks {
                task.group = nil
            }
            group.tasks = []
        }
        context.delete(group)
    }

    static func closeTab(_ tab: TaskTab, in context: ModelContext) {
        SurfaceManager.shared.closeSession(for: tab.id)
        HeadlessSessionManager.shared.closeSession(for: tab.id)
        guard let task = tab.task else {
            context.delete(tab)
            return
        }
        let remaining = task.orderedTabs.filter { $0.id != tab.id }
        if task.lastFocusedAgentTabID == tab.id {
            task.lastFocusedAgentTabID = remaining.first { $0.kind == .agent }?.id
        }
        if task.selectedTabID == tab.id {
            if let next = remaining.first {
                selectTab(next, in: task)
            } else {
                task.selectedTabID = nil
            }
        }
        TitleStore.shared.forget(tabID: tab.id)
        DraftStore.shared.forget(tabID: tab.id)
        BellStore.shared.forget(tabID: tab.id)
        TranscriptStore.shared.stopWatching(tabID: tab.id)
        UntrustedDirectoryStore.shared.clear(tabID: tab.id)
        context.delete(tab)
        reindex(remaining)
    }

    // MARK: - Reorder

    static func move(_ tasks: [WorkTask], from offsets: IndexSet, to destination: Int) {
        var ordered = tasks.sorted { $0.orderIndex < $1.orderIndex }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        reindex(ordered)
    }

    static func move(_ task: WorkTask, to group: TaskGroup?, siblings: [WorkTask]) {
        task.group = group
        task.orderIndex = nextIndex(after: siblings.filter { $0.id != task.id })
    }

    static func moveTabs(_ tabs: [TaskTab], from offsets: IndexSet, to destination: Int) {
        var ordered = tabs.sorted { $0.orderIndex < $1.orderIndex }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        reindex(ordered)
    }

    // MARK: - Ordering helpers

    private static func nextIndex(after items: [some Ordered]) -> Int {
        (items.map(\.orderIndex).max() ?? -1) + 1
    }

    private static func reindex(_ items: [some Ordered]) {
        for (index, item) in items.enumerated() where item.orderIndex != index {
            item.orderIndex = index
        }
    }
}

protocol Ordered: AnyObject {
    var orderIndex: Int { get set }
}

extension TaskGroup: Ordered {}
extension WorkTask: Ordered {}
extension TaskTab: Ordered {}

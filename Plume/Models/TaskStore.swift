import Foundation
import SwiftData
import SwiftUI // Array.move(fromOffsets:toOffset:)

/// Create/reorder/delete operations over the task tree.
///
/// Ordering is stored as a dense `orderIndex` per section, rewritten on every
/// move so drag-reorder and cross-group moves share one code path.
enum TaskStore {
    // MARK: - Create

    @discardableResult
    static func createTask(
        in context: ModelContext,
        title: String = "New Task",
        group: TaskGroup? = nil,
        siblings: [WorkTask]
    ) -> WorkTask {
        let task = WorkTask(title: title, orderIndex: nextIndex(after: siblings), group: group)
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        context.insert(task)
        context.insert(tab)
        task.tabs = [tab]
        task.selectedTabID = tab.id
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
        context.insert(tab)
        task.tabs.append(tab)
        task.selectedTabID = tab.id
        return tab
    }

    // MARK: - Delete

    static func delete(_ task: WorkTask, in context: ModelContext) {
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
        guard let task = tab.task else {
            context.delete(tab)
            return
        }
        let remaining = task.orderedTabs.filter { $0.id != tab.id }
        if task.selectedTabID == tab.id {
            task.selectedTabID = remaining.first?.id
        }
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

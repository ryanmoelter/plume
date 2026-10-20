import Foundation
import SwiftData
import SwiftUI // Array.move(fromOffsets:toOffset:)

/// Create/reorder/delete operations over the task tree.
///
/// Ordering is stored as a dense `orderIndex` per section, rewritten on every
/// move so drag-reorder and cross-group moves share one code path.
enum TaskStore {
    static let defaultGroupName = "New group"

    // MARK: - Create

    /// `defaultsToRecentFolder` seeds the workspace from the last folder used,
    /// so a new task is ready to run in the place you were already working.
    /// Off by default: it reads `UserDefaults` and shells out to `git`, which
    /// callers that just want a bare task shouldn't pay for.
    ///
    /// `inheritingFrom` seeds it instead from another task's workspace —
    /// ⌘N's selected-task case — and wins over `defaultsToRecentFolder` when
    /// both are given. A worktree task is inherited as a plain directory:
    /// the new task gets the same folder, not a worktree of its own.
    @discardableResult
    static func createTask(
        in context: ModelContext,
        title: String = "",
        group: TaskGroup? = nil,
        siblings: [WorkTask],
        defaultsToRecentFolder: Bool = false,
        inheritingFrom: WorkTask? = nil
    ) -> WorkTask {
        let task = WorkTask(title: title, orderIndex: nextIndex(after: siblings), group: group)
        if let source = inheritingFrom, let folder = source.workingDirectoryPath {
            task.workingDirectoryPath = folder
            task.repoPath = source.repoPath
            task.branchName = source.branchName
            task.workspaceKind = .directory
        } else if defaultsToRecentFolder, let folder = RecentFolders.mostRecent() {
            task.workingDirectoryPath = folder
            task.workspaceKind = .directory
            // Filled in once `git` answers: creating a task must not wait on
            // a subprocess, and nothing reads `repoPath` before then.
            Task { task.repoPath = await GitService.shared.repositoryRoot(containing: folder) }
        }
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        tab.provider = AppSettings.shared.defaultProvider
        tab.transport = tab.provider.resolvedTransport(preferring: AppSettings.shared.defaultAgentTransport)
        if tab.provider == .codex {
            tab.codexCollaborationMode = AppSettings.shared.defaultCodexCollaborationMode
        }
        context.insert(task)
        context.insert(tab)
        task.tabs = [tab]
        selectTab(tab, in: task)
        return task
    }

    @discardableResult
    static func createGroup(
        in context: ModelContext,
        name: String = defaultGroupName,
        existing: [TaskGroup]
    ) -> TaskGroup {
        let group = TaskGroup(name: name, orderIndex: nextIndex(after: existing))
        context.insert(group)
        return group
    }

    /// Lands in `pane`, or the focused pane when nil, at the end of its strip.
    @discardableResult
    static func addTab(
        to task: WorkTask,
        kind: TabKind,
        provider: AgentProviderKind? = nil,
        pane: Int? = nil,
        in context: ModelContext
    ) -> TaskTab {
        let paneIndex = min(max(pane ?? task.focusedPane, 0), task.paneCount - 1)
        let tab = TaskTab(kind: kind, orderIndex: nextIndex(after: task.tabs(inPane: paneIndex)), task: task)
        tab.paneIndex = paneIndex
        if kind == .agent {
            let provider = provider ?? AppSettings.shared.defaultProvider
            tab.provider = provider
            tab.transport = provider.resolvedTransport(
                preferring: AppSettings.shared.defaultAgentTransport
            )
            if provider == .codex {
                tab.codexCollaborationMode = AppSettings.shared.defaultCodexCollaborationMode
            }
        }
        context.insert(tab)
        task.tabs.append(tab)
        selectTab(tab, in: task)
        return tab
    }

    // MARK: - Selection

    /// The one place selection changes, so `lastFocusedAgentTabID` and each
    /// pane's selected tab cannot drift out of step with it. Selecting a tab
    /// focuses its pane.
    static func selectTab(_ tab: TaskTab, in task: WorkTask) {
        task.selectedTabID = tab.id
        if tab.kind == .agent {
            task.lastFocusedAgentTabID = tab.id
        }
        let remembered: [UUID?] = task.isSplit ? task.paneTabIDs : []
        if task.paneSelectedTabIDs != remembered {
            task.paneSelectedTabIDs = remembered
        }
    }

    /// ⌘1–9: counts within the focused pane's strip.
    static func selectTab(atIndex index: Int, in task: WorkTask) {
        let tabs = task.tabs(inPane: task.focusedPane)
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index], in: task)
    }

    /// Next and Previous Tab, wrapping within the focused pane's strip.
    static func cycleTab(by offset: Int, in task: WorkTask) {
        let tabs = task.tabs(inPane: task.focusedPane)
        guard let current = tabs.firstIndex(where: { $0.id == task.selectedTabID }) else { return }
        let next = ((current + offset) % tabs.count + tabs.count) % tabs.count
        selectTab(tabs[next], in: task)
    }

    // MARK: - Split

    enum SplitSide: Equatable {
        case left
        case right
    }

    /// Whether `tab` can move out into a new pane: only while unsplit, and
    /// never the last tab, which would leave its strip empty.
    static func canOpenInSplit(_ tab: TaskTab, in task: WorkTask) -> Bool {
        !task.isSplit && task.tabs.count > 1 && task.tabs.contains { $0.id == tab.id }
    }

    /// Moves `tab` out of its strip into a new pane on `side`, and focuses it.
    /// Already split, `tab` moves onto the end of the pane on `side` instead,
    /// unless it is already there, where it only takes focus.
    static func openInSplit(_ tab: TaskTab, side: SplitSide, in task: WorkTask) {
        if task.isSplit {
            let pane = side == .left ? 0 : task.paneCount - 1
            if tab.paneIndex == pane {
                selectTab(tab, in: task)
            } else {
                moveTab(tab, toPane: pane, in: task)
            }
            return
        }
        guard canOpenInSplit(tab, in: task) else { return }
        var panes = paneStates(of: task)
        remove(tab, from: &panes)
        let pane = PaneState(tabs: [tab], shown: tab.id)
        if side == .left { panes.insert(pane, at: 0) } else { panes.append(pane) }
        commit(panes, to: task, focusing: tab.id)
        selectTab(tab, in: task)
    }

    /// ⌘\ while unsplit: the focused tab moves into a new right pane.
    static func splitRight(in task: WorkTask) {
        guard let tab = focusedTab(of: task) else { return }
        openInSplit(tab, side: .right, in: task)
    }

    static func canSplitRight(in task: WorkTask) -> Bool {
        focusedTab(of: task).map { canOpenInSplit($0, in: task) } ?? false
    }

    private static func focusedTab(of task: WorkTask) -> TaskTab? {
        task.tabs.first { $0.id == task.selectedTabID }
    }

    /// Moves `tab` into `pane`'s strip at the gap `position` (counted in the
    /// strip as drawn, `tab` included), or onto its end. A tab arriving from
    /// another pane takes focus, and a pane left empty closes; a reorder
    /// within one strip leaves focus alone.
    static func moveTab(_ tab: TaskTab, toPane pane: Int, at position: Int? = nil, in task: WorkTask) {
        var panes = paneStates(of: task)
        guard panes.indices.contains(pane) else { return }
        let shownBefore = panes[pane].shown
        guard let source = remove(tab, from: &panes) else { return }
        let isReorder = source.pane == pane
        var destination = panes[pane].tabs
        var insertion = min(position ?? destination.count, destination.count)
        if isReorder, let position, position > source.index { insertion = min(position - 1, destination.count) }
        destination.insert(tab, at: insertion)
        panes[pane].tabs = destination
        if isReorder {
            panes[pane].shown = shownBefore
            commit(panes, to: task, focusing: task.selectedTabID)
            return
        }
        panes[pane].shown = tab.id
        commit(panes, to: task, focusing: tab.id)
        selectTab(tab, in: task)
    }

    /// Every pane's tabs join the leftmost strip, in pane order. The focused
    /// tab keeps focus.
    static func closeSplit(in task: WorkTask) {
        let panes = task.panes
        guard panes.count > 1 else { return }
        let merged = PaneState(tabs: panes.flatMap { $0 }, shown: task.selectedTabID)
        commit([merged], to: task, focusing: task.selectedTabID)
    }

    static func focusOtherPane(in task: WorkTask) {
        let shown = task.paneTabIDs
        guard shown.count > 1 else { return }
        let next = shown[(task.focusedPane + 1) % shown.count]
        guard let tab = task.tabs.first(where: { $0.id == next }) else { return }
        selectTab(tab, in: task)
    }

    /// Kept clear of the edges so a pane can never be dragged out of reach;
    /// the view enforces the real minimum width, which depends on the window.
    static let splitFractionRange: ClosedRange<Double> = 0.1...0.9

    static func setSplitFraction(_ fraction: Double, in task: WorkTask) {
        let clamped = min(max(fraction, splitFractionRange.lowerBound), splitFractionRange.upperBound)
        if task.splitFraction != clamped { task.splitFraction = clamped }
    }

    /// One pane while a split is being rearranged: its strip, and the tab it
    /// shows.
    private struct PaneState {
        var tabs: [TaskTab]
        var shown: UUID?
    }

    private static func paneStates(of task: WorkTask) -> [PaneState] {
        let panes = task.panes
        let shown = task.paneTabIDs(in: panes)
        return panes.enumerated().map { index, tabs in
            PaneState(tabs: tabs, shown: shown.indices.contains(index) ? shown[index] : tabs.first?.id)
        }
    }

    /// Takes `tab` out of its pane, which falls back to showing its first
    /// tab if it was showing `tab`. An emptied pane stays in `panes` until
    /// `commit`, so pane numbers hold in between.
    @discardableResult
    private static func remove(_ tab: TaskTab, from panes: inout [PaneState]) -> (pane: Int, index: Int)? {
        for pane in panes.indices {
            guard let index = panes[pane].tabs.firstIndex(where: { $0.id == tab.id }) else { continue }
            panes[pane].tabs.remove(at: index)
            if panes[pane].shown == tab.id { panes[pane].shown = panes[pane].tabs.first?.id }
            return (pane, index)
        }
        return nil
    }

    /// Writes `panes` back: drops empty ones, numbers the rest densely, and
    /// sets `focus` as the selected tab. Reads nothing from `task.tabs`, so a
    /// tab on its way out can still be listed there.
    private static func commit(_ panes: [PaneState], to task: WorkTask, focusing focus: UUID?) {
        let kept = panes.filter { !$0.tabs.isEmpty }
        for (paneIndex, pane) in kept.enumerated() {
            for (orderIndex, tab) in pane.tabs.enumerated() {
                if tab.paneIndex != paneIndex { tab.paneIndex = paneIndex }
                if tab.orderIndex != orderIndex { tab.orderIndex = orderIndex }
            }
        }
        let remembered: [UUID?] = kept.count > 1 ? kept.map(\.shown) : []
        if task.paneSelectedTabIDs != remembered { task.paneSelectedTabIDs = remembered }
        if task.selectedTabID != focus { task.selectedTabID = focus }
    }

    /// Takes `tab` out of `task`'s panes, as closing it or moving it to
    /// another task does. Returns the tab to focus in its place: the next one
    /// its pane shows, or, when its pane closes, the one the pane now in its
    /// place shows. Nil when no tab is left.
    @discardableResult
    private static func detach(_ tab: TaskTab, from task: WorkTask) -> UUID? {
        var panes = paneStates(of: task)
        guard let source = remove(tab, from: &panes) else { return task.selectedTabID }
        var focus = task.selectedTabID
        if focus == tab.id {
            if !panes[source.pane].tabs.isEmpty {
                focus = panes[source.pane].shown
            } else {
                let kept = panes.filter { !$0.tabs.isEmpty }
                focus = kept.isEmpty ? nil : kept[min(source.pane, kept.count - 1)].shown
            }
        }
        commit(panes, to: task, focusing: focus)
        return focus
    }

    // MARK: - Archive

    /// An archived task is out of sight, so leaving its agents running would
    /// burn a process and a remote-control bridge the user can no longer see
    /// or reach. Teardown matches `delete`.
    static func archive(_ task: WorkTask) {
        task.isArchived = true
        task.archivedAt = Date()
        for tab in task.tabs {
            forgetTab(tab)
        }
    }

    /// The processes are gone, so the tabs come back dormant and re-launch on
    /// demand. Re-registering is what stops the sidebar reading the status the
    /// task carried when it was archived.
    static func unarchive(_ task: WorkTask) {
        task.isArchived = false
        task.archivedAt = nil
        for tab in task.tabs where tab.kind == .agent {
            StatusEngine.shared.restore(tabID: tab.id, taskID: task.id)
            // Seeded before any watch below, so a fallback read racing in
            // ahead of a real transcript write finds the source already
            // recorded rather than being free to overwrite a higher-ranked
            // title this tab was given before archiving.
            if let source = tab.restorableTitleSource {
                TitleStore.shared.seedSource(source, forTab: tab.id)
            }
            if tab.transport == .terminal {
                AgentEventMonitor.shared.watch(taskID: task.id, tabID: tab.id)
            }
            if let path = tab.sessionJSONLPath, !path.isEmpty {
                AgentTitleMonitor.shared.watch(tabID: tab.id, transcriptPath: path)
                TranscriptStore.shared.watch(tabID: tab.id, transcriptPath: path)
            }
        }
    }

    // MARK: - Start fresh

    /// Discards Plume's link to a tab's conversation, so a later relaunch or
    /// resume starts clean. A live headless session keeps talking to the old
    /// conversation regardless (tracked separately), so while one exists this
    /// only drops `agentSessionID` and leaves the title and watches alone.
    static func startFresh(_ tab: TaskTab) {
        guard AgentSessionManager.shared.existingSession(for: tab.id) == nil else {
            tab.agentSessionID = nil
            return
        }
        tab.agentSessionID = nil
        tab.sessionJSONLPath = nil
        AgentTitleMonitor.shared.stopWatching(tabID: tab.id)
        TranscriptStore.shared.stopWatching(tabID: tab.id)
        TitleStore.shared.beginNewConversation(forTab: tab.id)
    }

    // MARK: - Delete

    /// The cascade delete removes the tabs, but their terminals are held
    /// outside SwiftData and have to be closed explicitly.
    static func delete(_ task: WorkTask, in context: ModelContext) {
        for tab in task.tabs {
            forgetTab(tab)
        }
        // The row that took this watch is going away with the task, and a
        // deleted row is not guaranteed to run its own teardown.
        if let directory = task.workingDirectoryPath {
            GitStateStore.shared.forget(directory: directory)
            PullRequestStore.shared.forget(directory: directory)
        }
        LinearMentionTracker.shared.forget(taskID: task.id)
        context.delete(task)
    }

    // MARK: - Worktree removal (shared by delete and archive)

    /// Removing the worktree is best-effort: if git refuses, the task stays
    /// so the user can resolve it rather than losing track of the directory.
    /// Its tabs are closed by then either way — they have to go before git
    /// touches the directory, and there is no reopening them if it declines.
    ///
    /// `finish` runs after a successful (or skipped) worktree removal, and is
    /// where the caller actually deletes or archives the task.
    static func removeWorktreeThenFinish(
        for task: WorkTask,
        removeWorktree: Bool,
        deleteBranch: Bool,
        in context: ModelContext,
        onError: @escaping (String) -> Void,
        finish: @escaping () -> Void
    ) {
        guard removeWorktree,
              let repository = task.repoPath,
              let path = task.workingDirectoryPath
        else {
            finish()
            return
        }
        for tab in task.tabs {
            forgetTab(tab)
        }
        Task {
            do {
                try await GitService.shared.removeWorktree(
                    repository: repository,
                    path: path,
                    branch: task.branchName,
                    deleteBranch: deleteBranch
                )
            } catch {
                onError(error.localizedDescription)
                return
            }
            finish()
        }
    }

    /// Everything a tab leaves outside SwiftData: its live sessions and every
    /// in-memory store keyed by tab id. Closing one tab, archiving its task and
    /// deleting its task all go through here, so none can drift into forgetting
    /// less than the others.
    static func forgetTab(_ tab: TaskTab) {
        let tabID = tab.id
        if let taskID = tab.task?.id {
            StatusEngine.shared.forget(tabID: tabID, taskID: taskID)
        }
        AgentEventMonitor.shared.stopWatching(tabID: tabID)
        AgentTitleMonitor.shared.stopWatching(tabID: tabID)
        SurfaceManager.shared.closeSession(for: tabID)
        AgentSessionManager.shared.closeSession(for: tabID)
        TitleStore.shared.forget(tabID: tabID)
        TabDirectoryStore.shared.forget(tabID: tabID)
        DraftStore.shared.forget(tabID: tabID)
        CommandModeRuns.shared.forget(tabID: tabID)
        BellStore.shared.forget(tabID: tabID)
        UnreadStore.shared.forget(tabID: tabID)
        SubagentCompletionTracker.shared.forget(tabID: tabID)
        SubagentStatusOverrides.shared.forget(tabID: tabID)
        InheritedForkHistory.shared.forget(tabID: tabID)
        TranscriptStore.shared.stopWatching(tabID: tabID)
        CodexSubagentStore.shared.forget(tabID: tabID)
        CodexItemStore.shared.forget(tabID: tabID)
        CodexCatalogStore.shared.forget(tabID: tabID)
        UntrustedDirectoryStore.shared.clear(tabID: tabID)
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
        forgetTab(tab)
        guard let task = tab.task else {
            context.delete(tab)
            return
        }
        let remaining = task.orderedTabs.filter { $0.id != tab.id }
        if task.lastFocusedAgentTabID == tab.id {
            task.lastFocusedAgentTabID = remaining.first { $0.kind == .agent }?.id
        }
        let wasFocused = task.selectedTabID == tab.id
        let focus = detach(tab, from: task)
        if wasFocused, let next = remaining.first(where: { $0.id == focus }), next.kind == .agent {
            task.lastFocusedAgentTabID = next.id
        }
        // A deleted tab stays in `tabs` until the context processes the
        // delete, and would hold its pane open until then.
        task.tabs.removeAll { $0.id == tab.id }
        context.delete(tab)
    }

    // MARK: - Linear links

    static func linearLinks(for task: WorkTask) -> LinearTaskLinks {
        TaskIntegrations.decode(task.integrationsData).linear ?? LinearTaskLinks()
    }

    /// Returns false for input that is not an identifier or issue URL.
    @discardableResult
    static func linkLinearIssue(_ identifier: String, to task: WorkTask) -> Bool {
        guard let id = LinearIdentifier.normalize(identifier) else { return false }
        updateLinearLinks(of: task) { $0.link(LinearIssueRef(identifier: id)) }
        return true
    }

    static func promoteLinearIssue(_ identifier: String, in task: WorkTask) {
        updateLinearLinks(of: task) { $0.promote(LinearIssueRef(identifier: identifier)) }
    }

    static func unlinkLinearIssue(_ identifier: String, from task: WorkTask) {
        updateLinearLinks(of: task) { $0.unlink(identifier) }
    }

    /// Returns whether a task owns the tab.
    @discardableResult
    static func recordAgentStartedLinearIssues(
        _ identifiers: Set<String>,
        inTaskOwningTab tabID: UUID,
        among tasks: [WorkTask]
    ) -> Bool {
        guard let task = tasks.first(where: { $0.tabs.contains { $0.id == tabID } }) else { return false }
        updateLinearLinks(of: task) { links in
            for identifier in identifiers.sorted() {
                links.recordAgentStarted(LinearIssueRef(identifier: identifier))
            }
        }
        return true
    }

    /// Writes only a changed value, so an idempotent call costs no save.
    private static func updateLinearLinks(of task: WorkTask, _ change: (inout LinearTaskLinks) -> Void) {
        var integrations = TaskIntegrations.decode(task.integrationsData)
        let before = integrations.linear ?? LinearTaskLinks()
        var links = before
        change(&links)
        guard links != before else { return }
        integrations.linear = links.isEmpty ? nil : links
        task.integrationsData = integrations.encoded()
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

    static func moveGroups(_ groups: [TaskGroup], from offsets: IndexSet, to destination: Int) {
        var ordered = groups.sorted { $0.orderIndex < $1.orderIndex }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        reindex(ordered)
    }

    // MARK: - Cross-task tab moves

    /// Reassigns `tab.task` and appends it to the end of `destination`'s
    /// leftmost strip, reindexing both tasks. Only the SwiftData relationship
    /// and ordering change — the tab's `id` is untouched, so `SurfaceManager` and
    /// `AgentSessionManager` (both keyed by tab id) keep serving the same
    /// running process across the move. Selects the tab in its new task by
    /// default so the drop reads as "the tab landed here."
    ///
    /// The tab keeps whatever `workingDirectoryPath` it already reported: a
    /// running process cannot be redirected to `destination`'s folder, so a
    /// moved tab stays in its original directory rather than silently
    /// pointing at the wrong one.
    static func moveTab(_ tab: TaskTab, to destination: WorkTask, selectAfterMove: Bool = true) {
        guard let source = tab.task, source.id != destination.id else { return }

        let remainingInSource = source.orderedTabs.filter { $0.id != tab.id }
        if source.lastFocusedAgentTabID == tab.id {
            source.lastFocusedAgentTabID = remainingInSource.first { $0.kind == .agent }?.id
        }
        detach(tab, from: source)

        tab.task = destination
        CodexTerminalMonitor.shared.reparent(tabID: tab.id, taskID: destination.id)
        CommandModeRuns.shared.reparent(tabID: tab.id, taskID: destination.id)
        AgentSessionManager.shared.reparent(tabID: tab.id, taskID: destination.id)
        StatusEngine.shared.reparent(tabID: tab.id, taskID: destination.id)
        tab.paneIndex = 0
        tab.orderIndex = nextIndex(after: destination.tabs.filter { $0.id != tab.id && $0.paneIndex == 0 })
        if selectAfterMove {
            selectTab(tab, in: destination)
        }
    }

    /// Splits `tab` out of its current task into a new, otherwise-empty task
    /// of its own. Shares `moveTab`'s guarantee that the surface keyed by the
    /// tab's id is never touched.
    @discardableResult
    static func splitTabIntoNewTask(
        _ tab: TaskTab,
        in context: ModelContext,
        group: TaskGroup? = nil,
        siblings: [WorkTask]
    ) -> WorkTask {
        let newTask = WorkTask(title: tab.displayTitle, orderIndex: nextIndex(after: siblings), group: group)
        context.insert(newTask)
        moveTab(tab, to: newTask)
        return newTask
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

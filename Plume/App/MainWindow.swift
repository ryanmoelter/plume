import AppKit
import SwiftUI
import SwiftData

struct MainWindow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: UUID?
    @State private var renamingTaskID: UUID?
    @State private var statusPersistence: StatusPersistence?
    @State private var statusNotifier: StatusNotifier?
    @State private var archiveShown = false
    @State private var tabPendingStartFresh: TaskTab?

    @Query(filter: #Predicate<WorkTask> { !$0.isArchived }, sort: \WorkTask.orderIndex)
    private var tasks: [WorkTask]
    @Query(sort: \TaskGroup.orderIndex)
    private var groups: [TaskGroup]

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, renamingTaskID: $renamingTaskID, archiveShown: $archiveShown)
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task)
            } else {
                ContentUnavailableView(
                    "No Task Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select a task, or press ⌘N to create one.")
                )
                .themeTint(colorScheme: colorScheme)
            }
        }
        // Below this the statusline's `.fixedSize()` segments — every one but
        // the branch chip, which is the one built to give way — start
        // overlapping before the composer's controls even finish collapsing
        // to icons (`ComposerControlsMetrics`). ~445pt of detail pane clears
        // that, plus the sidebar's own 200pt floor
        // (`SidebarView.navigationSplitViewColumnWidth`), with headroom.
        .frame(minWidth: 680, minHeight: 420)
        .sheet(isPresented: $archiveShown) {
            ArchiveView()
        }
        .focusedSceneValue(\.showArchiveAction) { archiveShown = true }
        .focusedSceneValue(\.selectAdjacentTask) { offset in
            let destination = SidebarKeyboardNavigation.destination(
                from: selection,
                in: navigableTasks.map(\.id),
                offset: offset
            )
            if let destination { selection = destination }
        }
        .focusedSceneValue(\.newTaskAction) {
            let group = selectedTask?.group
            let siblings = tasks.filter { $0.group?.id == group?.id }
            let task = TaskStore.createTask(
                in: context,
                group: group,
                siblings: siblings,
                defaultsToRecentFolder: true,
                inheritingFrom: selectedTask
            )
            selection = task.id
        }
        .focusedSceneValue(\.taskCommands, selectedTask.map { task in
            TaskCommands(
                addTab: { kind in TaskStore.addTab(to: task, kind: kind, in: context) },
                selectTab: { index in
                    let tabs = task.orderedTabs
                    guard tabs.indices.contains(index) else { return }
                    TaskStore.selectTab(tabs[index], in: task)
                },
                cycleTab: { offset in
                    let tabs = task.orderedTabs
                    guard !tabs.isEmpty,
                          let current = tabs.firstIndex(where: { $0.id == task.selectedTabID })
                    else { return }
                    let next = (current + offset + tabs.count) % tabs.count
                    TaskStore.selectTab(tabs[next], in: task)
                },
                closeSelectedTab: {
                    guard let tab = task.orderedTabs.first(where: { $0.id == task.selectedTabID })
                    else { return false }
                    TaskStore.closeTab(tab, in: context)
                    return true
                },
                archiveSelectedTask: {
                    task.isArchived = true
                    if selection == task.id { selection = nil }
                },
                startFreshSelectedTab: tabWithResumableSession(in: task).map { tab in
                    { tabPendingStartFresh = tab }
                }
            )
        })
        .confirmationDialog(
            "Start a fresh conversation?",
            isPresented: Binding(
                get: { tabPendingStartFresh != nil },
                set: { if !$0 { tabPendingStartFresh = nil } }
            )
        ) {
            Button("Start Fresh", role: .destructive) {
                tabPendingStartFresh?.agentSessionID = nil
                tabPendingStartFresh = nil
            }
            Button("Cancel", role: .cancel) { tabPendingStartFresh = nil }
        } message: {
            Text("This discards Plume's link to the previous conversation. The transcript stays on disk, but Plume won't be able to resume it.")
        }
        .onChange(of: selection) { _, id in
            LastOpenTask.save(id)
        }
        .onChange(of: Notifier.shared.pendingRoute) { _, route in
            guard let route else { return }
            follow(route)
            Notifier.shared.pendingRoute = nil
        }
        .task {
            statusPersistence = StatusPersistence(context: context)
            installNotifications()
            restoreStatusMonitoring()
            restoreLastOpenTask()
            #if DEBUG
            await SmokeHarness.runIfRequested(context: context, selection: $selection)
            #endif
        }
    }

    /// Both closures read live view state, so they are installed here rather
    /// than captured anywhere longer-lived.
    private func installNotifications() {
        Notifier.shared.audience = {
            NotificationAudience(
                isAppActive: NSApp.isActive,
                selectedTaskID: selection,
                selectedTabID: selectedTask?.selectedTabID
            )
        }
        statusNotifier = StatusNotifier { tabID in
            TitleStore.shared.title(forTab: tabID)
                ?? tasks.lazy.flatMap(\.tabs).first { $0.id == tabID }?.displayTitle
                ?? "Plume"
        }
    }

    /// A notification click selects its task, then its tab within that task.
    /// A task or tab deleted since the notification went out doesn't match,
    /// and the click does nothing.
    private func follow(_ route: Notifier.Route) {
        guard let task = tasks.first(where: { $0.id == route.taskID }) else { return }
        selection = task.id
        guard let tab = task.orderedTabs.first(where: { $0.id == route.tabID }) else { return }
        TaskStore.selectTab(tab, in: task)
        BellStore.shared.markSeen(tabID: tab.id)
    }

    private var selectedTask: WorkTask? {
        guard let selection else { return nil }
        return tasks.first { $0.id == selection }
    }

    /// Every task in the order the sidebar shows them, matching
    /// `SidebarView.navigableTasks` so ⌘] / ⌘[ walk the same order as the
    /// arrow keys do inside the sidebar.
    private var navigableTasks: [WorkTask] {
        groups.flatMap { group in tasks.filter { $0.group?.id == group.id } }
            + tasks.filter { $0.group == nil }
    }

    /// `tasks` excludes archived ones, so a task archived or deleted since the
    /// last launch simply doesn't match and the pane stays empty.
    private func restoreLastOpenTask() {
        guard selection == nil, let id = LastOpenTask.load() else { return }
        selection = tasks.first { $0.id == id }?.id
    }

    private func tabWithResumableSession(in task: WorkTask) -> TaskTab? {
        guard let tab = task.orderedTabs.first(where: { $0.id == task.selectedTabID }),
              tab.kind == .agent,
              let sessionID = tab.agentSessionID, !sessionID.isEmpty
        else { return nil }
        return tab
    }

    /// Replays events written while Plume was closed, then settles every tab
    /// to idle — nothing is running yet this launch, whatever the last event
    /// said.
    private func restoreStatusMonitoring() {
        AgentEventMonitor.shared.onSessionIDDiscovered = { tabID, sessionID in
            guard let tab = tasks.lazy.flatMap(\.tabs).first(where: { $0.id == tabID }),
                  tab.agentSessionID != sessionID
            else { return }
            tab.agentSessionID = sessionID
        }
        AgentEventMonitor.shared.onSessionCleared = { tabID in
            guard let tab = tasks.lazy.flatMap(\.tabs).first(where: { $0.id == tabID })
            else { return }
            // Dropped rather than replaced, because the new session's ID
            // arrives a moment later in its own event. Losing auto-resume if
            // Plume dies in between costs a message; keeping the stale ID
            // would silently restore the conversation the user discarded.
            tab.agentSessionID = nil
            tab.sessionJSONLPath = nil
            // The chat would otherwise keep rendering the conversation the
            // user just discarded, until the replacement session's first
            // write.
            TranscriptStore.shared.stopWatching(tabID: tabID)
        }
        AgentEventMonitor.shared.onTranscriptPathDiscovered = { tabID, path in
            guard let tab = tasks.lazy.flatMap(\.tabs).first(where: { $0.id == tabID })
            else { return }
            if tab.sessionJSONLPath != path {
                tab.sessionJSONLPath = path
            }
            AgentTitleMonitor.shared.watch(tabID: tabID, transcriptPath: path)
            TranscriptStore.shared.watch(tabID: tabID, transcriptPath: path)
        }
        AgentTitleMonitor.shared.onTitleDiscovered = { tabID, title in
            TitleStore.shared.setTitle(title, forTab: tabID)
        }
        TitleStore.shared.onTitleChanged = { tabID, title in
            guard let tab = tasks.lazy.flatMap(\.tabs).first(where: { $0.id == tabID }),
                  tab.title != title
            else { return }
            tab.title = title
        }

        for task in tasks {
            for tab in task.tabs where tab.kind == .agent {
                switch tab.transport {
                case .terminal:
                    AgentEventMonitor.shared.watch(taskID: task.id, tabID: tab.id)
                case .headless:
                    // The stream carries status directly once resumed; hook
                    // events are a TUI-only concern.
                    break
                }
                StatusEngine.shared.setStatus(.idle, taskID: task.id, tabID: tab.id)
                if let path = tab.sessionJSONLPath, !path.isEmpty {
                    AgentTitleMonitor.shared.watch(tabID: tab.id, transcriptPath: path)
                    TranscriptStore.shared.watch(tabID: tab.id, transcriptPath: path)
                }
            }
        }
    }
}

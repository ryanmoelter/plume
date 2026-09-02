import SwiftUI
import SwiftData

struct MainWindow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: UUID?
    @State private var renamingTaskID: UUID?
    @State private var statusPersistence: StatusPersistence?
    @State private var archiveShown = false
    @State private var tabPendingStartFresh: TaskTab?

    @Query(filter: #Predicate<WorkTask> { !$0.isArchived })
    private var tasks: [WorkTask]

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
        .sheet(isPresented: $archiveShown) {
            ArchiveView()
        }
        .focusedSceneValue(\.showArchiveAction) { archiveShown = true }
        .focusedSceneValue(\.newTaskAction) {
            let ungrouped = tasks.filter { $0.group == nil }
            let task = TaskStore.createTask(
                in: context, siblings: ungrouped, defaultsToRecentFolder: true
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
                    else { return }
                    TaskStore.closeTab(tab, in: context)
                },
                archiveSelectedTask: {
                    task.isArchived = true
                    if selection == task.id { selection = nil }
                },
                startFreshSelectedTab: tabWithResumableSession(in: task).map { tab in
                    { tabPendingStartFresh = tab }
                },
                toggleRenderMode: selectedAgentTab(in: task).map { tab in
                    { tab.renderMode = tab.renderMode == .chat ? .terminal : .chat }
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
        .task {
            statusPersistence = StatusPersistence(context: context)
            restoreStatusMonitoring()
            #if DEBUG
            await SmokeHarness.runIfRequested(context: context, selection: $selection)
            #endif
        }
    }

    private var selectedTask: WorkTask? {
        guard let selection else { return nil }
        return tasks.first { $0.id == selection }
    }

    private func selectedAgentTab(in task: WorkTask) -> TaskTab? {
        task.orderedTabs.first { $0.id == task.selectedTabID && $0.kind == .agent }
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

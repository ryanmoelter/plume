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
    @State private var importShown = false
    @State private var fullDiskAccessShown = false
    @State private var tabPendingStartFresh: TaskTab?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var pendingWorktreeRemoval: WorktreeRemovalPrompt.PendingRemoval?
    @State private var worktreeRemovalError: String?
    /// Starts generous so the sidebar's max width is unclamped until the
    /// first real measurement lands.
    @State private var windowWidth: CGFloat = .infinity

    @Query(filter: #Predicate<WorkTask> { !$0.isArchived }, sort: \WorkTask.orderIndex)
    private var tasks: [WorkTask]
    @Query(sort: \TaskGroup.orderIndex)
    private var groups: [TaskGroup]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
            // Chrome, not chat: the fixed default rather than the user's chat
            // font size, so enlarging the conversation's type leaves the
            // sidebar's own scale where it is.
            .plumeTheme(
                bodySize: CGFloat(AppSettings.defaultChatFontSize),
                setsAmbientFont: false
            )
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            windowWidth = newWidth
        }
        .frame(
            minWidth: WindowMetrics.minimumWidth(sidebarVisible: columnVisibility != .detailOnly),
            minHeight: WindowMetrics.minimumHeight
        )
        .sheet(isPresented: $archiveShown) {
            ArchiveView()
        }
        .sheet(isPresented: $importShown) {
            ImportSheet()
        }
        .sheet(isPresented: $fullDiskAccessShown) {
            FullDiskAccessSheet {
                fullDiskAccessShown = false
            }
        }
        .task {
            // The flag is set even when the sheet is skipped, so a user who
            // already has access is never shown it later either.
            guard !AppSettings.shared.hasPromptedForFullDiskAccess else { return }
            AppSettings.shared.hasPromptedForFullDiskAccess = true
            fullDiskAccessShown = !FullDiskAccess.isGranted
        }
        .focusedSceneValue(\.showArchiveAction) { archiveShown = true }
        .focusedSceneValue(\.showImportAction) { importShown = true }
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
                    requestRemoval(of: task, verb: .archive)
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
            Text("This discards \(AppIdentity.displayName)'s link to the previous conversation. The transcript stays on disk, but \(AppIdentity.displayName) won't be able to resume it.")
        }
        .modifier(worktreeRemovalDialog)
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
            // Held by the singleton, not this view: the assertion has to
            // outlive a closed window, or the Mac would sleep mid-turn.
            KeepAwakeCoordinator.shared.start()
            restoreStatusMonitoring()
            restoreLastOpenTask()
            StartupWarmPass.shared.warm(directories: StartupWarmPass.directories(for: tasks))
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
                ?? AppIdentity.displayName
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

    /// Broken out of `body` because the full `SidebarView(...)` initializer
    /// call inline there defeats the type checker's time budget.
    private var sidebar: some View {
        SidebarView(
            selection: $selection,
            renamingTaskID: $renamingTaskID,
            archiveShown: $archiveShown,
            windowWidth: windowWidth,
            requestArchive: { requestRemoval(of: $0, verb: .archive) },
            requestDelete: { requestRemoval(of: $0, verb: .delete) }
        )
    }

    /// Broken out of `body` for the same reason as `sidebar`: another
    /// `confirmationDialog`/`alert` pair inline there tips the whole
    /// expression past the type checker's time budget.
    private var worktreeRemovalDialog: WorktreeRemovalDialogModifier {
        WorktreeRemovalDialogModifier(
            pendingRemoval: $pendingWorktreeRemoval,
            removalError: $worktreeRemovalError,
            onConfirm: finishRemoval
        )
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

    /// Entry point for both the sidebar's context menu and ⌘⌃A: a task that
    /// owns a Plume-created worktree asks before either deleting or archiving
    /// touches it, since both would otherwise silently orphan the directory.
    /// A task without one skips straight to `finishRemoval`, exactly as
    /// today.
    private func requestRemoval(of task: WorkTask, verb: WorktreeRemovalVerb) {
        guard WorktreeRemovalPrompt.needsConfirmation(for: task) else {
            finishRemoval(task, verb: verb, removeWorktree: false, deleteBranch: false)
            return
        }
        guard let path = task.workingDirectoryPath else {
            pendingWorktreeRemoval = .init(task: task, verb: verb, dirtySummary: nil)
            return
        }
        // Checks for uncommitted work before presenting the confirmation, so
        // the dialog's copy is settled before it ever appears rather than
        // mutating under the user once the check resolves.
        Task {
            let changes = await GitService.shared.uncommittedChanges(in: path)
            pendingWorktreeRemoval = .init(
                task: task,
                verb: verb,
                dirtySummary: changes.isEmpty ? nil : WorktreeRemovalPrompt.describe(changes)
            )
        }
    }

    private func finishRemoval(_ task: WorkTask, verb: WorktreeRemovalVerb, removeWorktree: Bool, deleteBranch: Bool) {
        TaskStore.removeWorktreeThenFinish(
            for: task,
            removeWorktree: removeWorktree,
            deleteBranch: deleteBranch,
            in: context,
            onError: { message in
                worktreeRemovalError = message
                pendingWorktreeRemoval = nil
            },
            finish: {
                if selection == task.id { selection = nil }
                switch verb {
                case .delete: TaskStore.delete(task, in: context)
                case .archive: TaskStore.archive(task)
                }
                pendingWorktreeRemoval = nil
            }
        )
    }

    private func tabWithResumableSession(in task: WorkTask) -> TaskTab? {
        guard let tab = task.orderedTabs.first(where: { $0.id == task.selectedTabID }),
              tab.kind == .agent,
              let sessionID = tab.agentSessionID, !sessionID.isEmpty
        else { return nil }
        return tab
    }

    /// Replays events written while Plume was closed, then settles every tab
    /// to `notStarted` — nothing is running yet this launch, whatever the
    /// last event said, and claiming a turn ended would overstate that.
    private func restoreStatusMonitoring() {
        CodexSharedAppServer.shared.adoptRemoteThread = { thread in
            await CodexRemoteThreadAdopter.adopt(thread: thread, in: context)
        }
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
        AgentSessionManager.shared.titleContextProvider = { tabID in
            guard let tab = tasks.lazy.flatMap(\.tabs).first(where: { $0.id == tabID })
            else { return nil }
            return (tab.transport, tab.task?.title)
        }
        TitleStore.shared.onTitleChanged = { tabID, title in
            guard let tab = tasks.lazy.flatMap(\.tabs).first(where: { $0.id == tabID }),
                  tab.title != title
            else { return }
            tab.title = title
        }

        for task in tasks {
            for tab in task.tabs where tab.kind == .agent {
                switch (tab.provider, tab.transport) {
                case (.claudeCode, .terminal):
                    AgentEventMonitor.shared.watch(taskID: task.id, tabID: tab.id)
                case (.claudeCode, .headless), (.codex, _):
                    // The stream carries status directly once resumed; hook
                    // events are a Claude Code TUI concern, and Codex has no
                    // hook mechanism to watch at all.
                    break
                }
                StatusEngine.shared.restore(tabID: tab.id, taskID: task.id)
                if let path = tab.sessionJSONLPath, !path.isEmpty {
                    AgentTitleMonitor.shared.watch(tabID: tab.id, transcriptPath: path)
                    TranscriptStore.shared.watch(tabID: tab.id, transcriptPath: path)
                }
            }
        }
    }
}

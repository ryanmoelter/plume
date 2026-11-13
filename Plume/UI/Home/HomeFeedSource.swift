import Foundation

/// Reads the live state `HomeFeed` sorts. The closures stand in for the shared
/// stores, so a test can supply its own.
struct HomeFeedSource {
    var status: (UUID) -> TaskStatus
    var isUnread: (UUID) -> Bool
    var isDormant: (UUID) -> Bool = { _ in false }
    var workStarted: (UUID) -> Date?
    var permissionToolName: (UUID) -> String?
    var preview: (TaskTab) -> String?
    var taskTitle: (WorkTask) -> String
    var tabTitle: (TaskTab) -> String
    var context: (WorkTask, TaskTab) -> HomeRowContext = { _, _ in HomeRowContext() }
    var sideWork: (TaskTab) -> [HomeSideWork] = { _ in [] }

    static var live: HomeFeedSource {
        HomeFeedSource(
            status: { StatusEngine.shared.status(forTab: $0) },
            isUnread: { UnreadStore.shared.isUnread(tabID: $0) },
            isDormant: { StatusEngine.shared.isDormant(tabID: $0) },
            workStarted: { StatusEngine.shared.workStarted(forTab: $0) },
            // `existingSession`, never `session(for:)`, which would create one.
            permissionToolName: { tabID in
                AgentSessionManager.shared.existingSession(for: tabID)?
                    .pendingPermissions.first { $0.interactive == nil }?.displayName
            },
            preview: { tab in
                // Codex keeps its messages only while its chat is mounted.
                guard tab.provider == .claudeCode,
                      let messages = TranscriptStore.shared.transcript(forTab: tab.id)?.messages
                else { return nil }
                return HomePreviewCache.shared.preview(forTab: tab.id, messages: messages)
            },
            taskTitle: { TitleStore.shared.displayTitle(for: $0) },
            tabTitle: { TitleStore.shared.title(forTab: $0.id) ?? $0.displayTitle },
            context: HomeRowContext.live(task:tab:),
            sideWork: HomeSideWork.live(tab:)
        )
    }
}

extension HomeRowContext {
    /// Reads only what the sidebar's watches have already cached; Home starts
    /// no lookup of its own.
    static func live(task: WorkTask, tab: TaskTab) -> HomeRowContext {
        let directory = TabDirectoryStore.shared.directory(for: tab)
        let checkout = CheckoutFactsStore.shared.facts(for: directory)
        let showsPullRequests = AppSettings.shared.showsPullRequestStatus
        var context = HomeRowContext(
            project: TaskRowDetails.projectName(for: .init(directory: directory, checkout: checkout)),
            branch: directory.flatMap(task.displayedBranch(in:)) ?? task.branchName,
            isWorktree: checkout?.isWorktree ?? false,
            isLocalOnly: showsPullRequests && PullRequestStore.shared.state(for: directory) == .localOnly
        )
        if showsPullRequests {
            // This tab's own checkout leads.
            var directories = task.agentDirectories
            if let directory {
                directories.removeAll { $0 == directory }
                directories.insert(directory, at: 0)
            }
            var seen: Set<Int> = []
            for directory in directories {
                guard case .pullRequest(let pullRequest) = PullRequestStore.shared.state(for: directory),
                      seen.insert(pullRequest.number).inserted
                else { continue }
                context.pullRequests.append(Reference(
                    id: "#\(pullRequest.number)",
                    icon: .pullRequest(number: pullRequest.number, state: pullRequest.state, isDraft: pullRequest.isDraft)
                ))
            }
        }
        if AppSettings.shared.showsLinearIssues, LinearStore.shared.isConfigured {
            context.issues = LinearStore.shared.links(for: task, branches: task.linearBranches)
                .filter { $0.role == .working }
                .map { link in
                    Reference(
                        id: link.identifier,
                        icon: LinearStore.shared.state(for: link.identifier)?.issue
                            .map { ReferenceChipIcon.linear($0) }
                    )
                }
        }
        return context
    }
}

extension HomeSideWork {
    /// Reads the stores that already feed `setSubagentActivity` and the
    /// keep-awake reasons; Home tracks nothing of its own.
    static func live(tab: TaskTab) -> [HomeSideWork] {
        let subagents = switch tab.provider {
        case .claudeCode: TranscriptStore.shared.subagents(forTab: tab.id)
        case .codex: CodexSubagentStore.shared.subagents(forTab: tab.id)
        }
        return items(
            subagents: subagents,
            hasSettled: { SubagentCompletionTracker.shared.hasSettled($0, tabID: tab.id) },
            backgroundTasks: BackgroundTaskTracker.shared.inFlight(tabID: tab.id)
        )
    }
}

extension HomeFeed {
    /// The length of "Needs you", from per-tab status and unread state alone,
    /// so a caller that only shows the number doesn't depend on transcripts.
    static func needsYouCount(
        tasks: [WorkTask],
        status: (UUID) -> TaskStatus,
        isUnread: (UUID) -> Bool
    ) -> Int {
        liveAgentTabs(of: tasks).reduce(0) { count, pair in
            needsYou(status: status(pair.tab.id), isUnread: isUnread(pair.tab.id)) ? count + 1 : count
        }
    }

    /// Every live agent tab of the unarchived tasks, in sidebar order.
    private static func liveAgentTabs(of tasks: [WorkTask]) -> [(task: WorkTask, tab: TaskTab)] {
        tasks.filter { !$0.isArchived }.flatMap { task in
            task.orderedLiveTabs.filter { $0.kind == .agent }.map { (task, $0) }
        }
    }

    /// Every live agent tab of `tasks`, which are in sidebar order.
    init(tasks: [WorkTask], source: HomeFeedSource) {
        let entries = Self.liveAgentTabs(of: tasks).map { task, tab in
            let isUnread = source.isUnread(tab.id)
            let appearance = SidebarTaskAppearance(task: task, settings: .shared)
            let status = source.status(tab.id)
            return Entry(
                taskID: task.id,
                tabID: tab.id,
                taskTitle: source.taskTitle(task),
                tabTitle: source.tabTitle(tab),
                status: status,
                isUnread: isUnread,
                hasSession: tab.hasAgentSession,
                isDormant: source.isDormant(tab.id),
                lastOpenedAt: task.lastOpenedAt ?? task.createdAt,
                permissionToolName: source.permissionToolName(tab.id),
                workStartedAt: source.workStarted(tab.id),
                preview: isUnread ? source.preview(tab) : nil,
                iconName: task.iconName,
                iconTint: appearance.iconTint,
                barTint: appearance.barTint,
                context: source.context(task, tab),
                sideWork: source.sideWork(tab)
            )
        }
        self.init(entries: entries)
    }
}

/// Each tab's preview, recomputed only when its last message changes, so a
/// Home redraw doesn't rescan a transcript that hasn't moved.
final class HomePreviewCache {
    static let shared = HomePreviewCache()

    private struct Key: Equatable {
        let messageID: String
        let blockCount: Int
        let textLength: Int
        let isLive: Bool
    }

    private var previews: [UUID: (key: Key, preview: String?)] = [:]

    func preview(forTab tabID: UUID, messages: [ChatMessage]) -> String? {
        guard let last = messages.last else { return nil }
        let key = Key(
            messageID: last.id,
            blockCount: last.blocks.count,
            textLength: last.blocks.reduce(0) { total, block in
                if case .markdown(let text) = block { total + text.utf16.count } else { total }
            },
            isLive: last.isLive
        )
        if let cached = previews[tabID], cached.key == key { return cached.preview }
        let preview = HomeFeed.preview(of: messages)
        previews[tabID] = (key, preview)
        return preview
    }

    func forget(tabID: UUID) {
        previews[tabID] = nil
    }
}

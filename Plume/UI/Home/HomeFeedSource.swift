import Foundation

/// Reads the live state `HomeFeed` sorts. The closures stand in for the shared
/// stores, so a test can supply its own.
struct HomeFeedSource {
    var status: (UUID) -> TaskStatus
    var isUnread: (UUID) -> Bool
    var isDormant: (UUID) -> Bool
    var workStarted: (UUID) -> Date?
    var permissionToolName: (UUID) -> String?
    var preview: (TaskTab) -> String?
    var taskTitle: (WorkTask) -> String
    var tabTitle: (TaskTab) -> String

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
            tabTitle: { TitleStore.shared.title(forTab: $0.id) ?? $0.displayTitle }
        )
    }
}

extension HomeFeed {
    /// Every live agent tab of `tasks`, which are in sidebar order.
    init(tasks: [WorkTask], source: HomeFeedSource) {
        let entries = tasks.filter { !$0.isArchived }.flatMap { task in
            task.orderedLiveTabs.filter { $0.kind == .agent }.map { tab in
                let isUnread = source.isUnread(tab.id)
                return Entry(
                    taskID: task.id,
                    tabID: tab.id,
                    taskTitle: source.taskTitle(task),
                    tabTitle: source.tabTitle(tab),
                    status: source.status(tab.id),
                    isUnread: isUnread,
                    isDormant: source.isDormant(tab.id),
                    hasSession: !(tab.agentSessionID ?? "").isEmpty,
                    permissionToolName: source.permissionToolName(tab.id),
                    workStartedAt: source.workStarted(tab.id),
                    preview: isUnread ? source.preview(tab) : nil
                )
            }
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
        let isLive: Bool
    }

    private var previews: [UUID: (key: Key, preview: String?)] = [:]

    func preview(forTab tabID: UUID, messages: [ChatMessage]) -> String? {
        guard let last = messages.last else { return nil }
        let key = Key(messageID: last.id, blockCount: last.blocks.count, isLive: last.isLive)
        if let cached = previews[tabID], cached.key == key { return cached.preview }
        let preview = HomeFeed.preview(of: messages)
        previews[tabID] = (key, preview)
        return preview
    }
}

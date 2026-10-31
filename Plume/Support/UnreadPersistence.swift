import Foundation

/// Stores chat tabs' unread marks on `TaskTab.unreadMessageID`, and brings
/// them back at launch for `UnreadStore` to confirm against each tab's
/// transcript. Terminal tabs keep theirs in memory only.
@MainActor
struct UnreadPersistence {
    var unread: UnreadStore = .shared
    var transcripts: TranscriptStore = .shared
    var codexItems: CodexItemStore = .shared
    var codexCache: CodexHistoryCache? = .shared

    static func persists(_ tab: TaskTab) -> Bool {
        tab.kind == .agent && tab.transport == .headless
    }

    func install(tab: @escaping (UUID) -> TaskTab?) {
        unread.onStoredMarkChanged = { tabID, messageID in
            guard let tab = tab(tabID), tab.unreadMessageID != messageID,
                  messageID == nil || Self.persists(tab)
            else { return }
            tab.unreadMessageID = messageID
        }
        transcripts.onLatestMessageChanged = { [unread] tabID, messageID in
            guard let tab = tab(tabID), Self.persists(tab), tab.provider == .claudeCode else { return }
            unread.latestMessageChanged(tabID: tabID, to: messageID)
        }
        codexItems.onLatestItemChanged = { [unread] tabID, itemID in
            guard let tab = tab(tabID), Self.persists(tab), tab.provider == .codex else { return }
            unread.latestMessageChanged(tabID: tabID, to: itemID)
        }
    }

    /// Call after `StatusEngine.restore`. A Claude Code tab is confirmed by
    /// the transcript read its watch already runs. A Codex tab's items load
    /// only when its chat mounts, so its cached snapshot confirms it instead.
    @discardableResult
    func restore(_ tabs: some Sequence<TaskTab>) -> [Task<Void, Never>] {
        var cacheReads: [Task<Void, Never>] = []
        for tab in tabs {
            guard let messageID = tab.unreadMessageID else { continue }
            guard Self.persists(tab) else {
                tab.unreadMessageID = nil
                continue
            }
            unread.restore(tabID: tab.id, messageID: messageID)
            guard tab.provider == .codex else { continue }
            guard let threadID = tab.agentSessionID, !threadID.isEmpty, let codexCache else {
                unread.latestMessageChanged(tabID: tab.id, to: nil)
                continue
            }
            let tabID = tab.id
            cacheReads.append(Task { [unread] in
                let latest = await codexCache.load(tabID: tabID, threadID: threadID)?.entries.last?.stableID
                guard unread.isAwaitingRestore(tabID: tabID) else { return }
                unread.latestMessageChanged(tabID: tabID, to: latest)
            })
        }
        return cacheReads
    }
}

import Foundation

@MainActor
extension TaskTab {
    /// Whether the tab has a conversation to be named after, saved or live.
    var hasConversation: Bool {
        agentSessionID?.isEmpty == false || sessionJSONLPath?.isEmpty == false
            || AgentSessionManager.shared.existingSession(for: id) != nil
            || SurfaceManager.shared.existingSession(for: id) != nil
    }
}

@MainActor
extension TitleStore {
    /// What the tab strip and the sidebar call a tab. The live title wins over
    /// the snapshot on the tab, which is only there to label it before
    /// anything reconnects.
    func chipTitle(for tab: TaskTab, hasConversation: Bool) -> String {
        title(forTab: tab.id) ?? (tab.kind == .agent && !hasConversation && tab.title == nil ? "Chat" : tab.displayTitle)
    }

    func chipTitle(for tab: TaskTab) -> String {
        chipTitle(for: tab, hasConversation: tab.hasConversation)
    }
}

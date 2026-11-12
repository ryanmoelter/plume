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
    /// anything reconnects. `hasConversation` is read only when nothing else
    /// names the tab, so a titled tab never observes the session managers.
    func chipTitle(for tab: TaskTab, hasConversation: @autoclosure () -> Bool) -> String {
        if let live = title(forTab: tab.id) { return live }
        return tab.kind == .agent && tab.title == nil && !hasConversation() ? "Chat" : tab.displayTitle
    }

    func chipTitle(for tab: TaskTab) -> String {
        chipTitle(for: tab, hasConversation: tab.hasConversation)
    }
}

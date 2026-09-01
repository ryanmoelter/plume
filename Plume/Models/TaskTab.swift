import Foundation
import SwiftData

@Model
final class TaskTab {
    var id: UUID = UUID()
    var kindRaw: String = TabKind.agent.rawValue
    var title: String?
    var orderIndex: Int = 0
    var task: WorkTask?

    var renderModeRaw: String = TabRenderMode.chat.rawValue

    var providerID: String?
    /// Passed to `claude --resume` when the user resumes this tab.
    var agentSessionID: String?
    var sessionJSONLPath: String?

    /// Reserved for extra launch args and statusline preferences.
    var launchArgumentsData: Data?

    init(kind: TabKind, orderIndex: Int, task: WorkTask? = nil) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.orderIndex = orderIndex
        self.task = task
        self.providerID = kind == .agent ? ClaudeCodeProviderID : nil
    }

    var kind: TabKind {
        get { TabKind(rawValue: kindRaw) ?? .agent }
        set { kindRaw = newValue.rawValue }
    }

    /// Only meaningful for an agent tab; a terminal tab has nothing to render
    /// a chat from.
    var renderMode: TabRenderMode {
        get { TabRenderMode(rawValue: renderModeRaw) ?? .chat }
        set { renderModeRaw = newValue.rawValue }
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return kind == .agent ? "Agent" : "Terminal"
    }
}

let ClaudeCodeProviderID = "claude-code"

import Foundation
import SwiftData

@Model
final class TaskTab {
    var id: UUID = UUID()
    var kindRaw: String = TabKind.agent.rawValue
    var title: String?
    var orderIndex: Int = 0
    var task: WorkTask?

    /// Tombstone: `TabRenderMode` was removed (transport alone now decides a
    /// tab's view), but the stored property stays so lightweight migration
    /// keeps working. Unused.
    var renderModeRaw: String?

    /// Optional for the same migration reason; `transport` defaults new and
    /// existing tabs alike to headless, per `AppSettings.defaultAgentTransport`.
    var transportRaw: String?

    var providerID: String?
    /// Where this tab last reported being, which is not always its task's
    /// folder: an agent that moves into a worktree stays there across a
    /// relaunch. Nil until the tab reports, so a new tab starts at its task's
    /// folder. `TabDirectoryStore` owns the live value and writes through here.
    var workingDirectoryPath: String?
    /// The CLI's own identifier for this conversation, passed back to it to
    /// resume: a Claude Code `session_id`, or a Codex `threadId`.
    var agentSessionID: String?
    var sessionJSONLPath: String?
    /// The model's context window, as reported by the last completed turn.
    /// A resumed headless session has no window until it takes a turn in this
    /// process, so this snapshot covers the gap.
    var contextWindowTokens: Int?

    /// Snapshot of the session's last-seen permission mode, so a reopened tab
    /// starts back where the user left it rather than at the task or app
    /// default. Nil until a headless session reports one.
    var permissionModeRaw: String?
    /// Codex collaboration mode is independent of its permissions profile.
    var codexCollaborationModeRaw: String = "default"
    /// Snapshot of the session's last-seen effort. There is no way to read a
    /// running session's effort back from the CLI, so this is the only record
    /// of it across a relaunch.
    var effortRaw: String?
    /// Only explicit effort choices override a Codex resume response.
    var isEffortUserChosen: Bool = false
    /// The model to launch with, chosen before the tab has a session. Nil
    /// leaves `--model` off, so the CLI picks its own default. A running
    /// session overwrites this with whatever it reports, so on its own it
    /// records what the conversation ran on, not what the user asked for.
    var modelRaw: String?
    /// Whether `modelRaw` is a user's pick rather than a snapshot of the
    /// running session. Only a pick may pass `--model` to a resume, which
    /// would otherwise override the model the conversation restores.
    var isModelUserChosen: Bool = false

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

    /// Only meaningful for an agent tab. Nil means the tab predates this
    /// field, or is new but hasn't been stamped yet — `TaskStore` stamps
    /// `AppSettings.defaultAgentTransport` onto every agent tab it creates,
    /// right after this initializer runs.
    var transport: AgentTransport {
        get { transportRaw.flatMap(AgentTransport.init(rawValue:)) ?? .headless }
        set { transportRaw = newValue.rawValue }
    }

    /// Only meaningful for an agent tab. A nil or unrecognized `providerID`
    /// reads as Claude Code, which is what carries tabs written before this
    /// field meant anything.
    var provider: AgentProviderKind {
        get { providerID.flatMap(AgentProviderKind.init(rawValue:)) ?? .claudeCode }
        set { providerID = newValue.rawValue }
    }

    var permissionMode: PermissionMode? {
        get { permissionModeRaw.flatMap(PermissionMode.init(rawValue:)) }
        set { permissionModeRaw = newValue?.rawValue }
    }

    var effort: AgentEffort? {
        get {
            guard let raw = effortRaw, let effort = AgentEffort.recognizing(raw) else { return nil }
            return provider == .codex || provider.efforts.contains(effort) ? effort : nil
        }
        set { effortRaw = newValue?.rawValue }
    }

    var model: AgentModel? {
        get { modelRaw.flatMap { AgentModel.recognizing($0, provider: provider) } }
        set { modelRaw = newValue?.id }
    }

    var codexCollaborationMode: CodexCollaborationMode {
        get { CodexCollaborationMode(rawValue: codexCollaborationModeRaw) ?? .default }
        set { codexCollaborationModeRaw = newValue.rawValue }
    }

    var permissionPreset: AgentPermissionPreset? {
        get {
            guard let raw = permissionModeRaw else { return nil }
            return provider.permissionPresets.first { $0.id == raw }
                ?? AgentPermissionPreset(id: raw, label: raw)
        }
        set { permissionModeRaw = newValue?.id }
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return kind == .agent ? "Agent" : "Terminal"
    }
}

let ClaudeCodeProviderID = AgentProviderKind.claudeCode.rawValue

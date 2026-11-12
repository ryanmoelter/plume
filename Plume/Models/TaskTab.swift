import Foundation
import SwiftData

@Model
final class TaskTab {
    var id: UUID = UUID()
    var kindRaw: String = TabKind.agent.rawValue
    var title: String?
    /// Where `title` came from, carried across a relaunch so `TitleStore` can
    /// restore each tab's rank before anything re-reads a transcript — see
    /// `TitleSource` and `TitleStore.setTitle(_:forTab:source:)`.
    var titleSourceRaw: String?
    /// Dense within the tab's pane, not across the task.
    var orderIndex: Int = 0
    /// Which of its task's panes the tab sits in, counted from the left.
    var paneIndex: Int = 0
    var task: WorkTask?

    /// Tombstone: `TabRenderMode` was removed (transport alone now decides a
    /// tab's view), but the stored property stays so lightweight migration
    /// keeps working. Unused.
    var renderModeRaw: String?

    /// Optional for the same migration reason; `transport` defaults new and
    /// existing tabs alike to headless, per `AppSettings.defaultAgentTransport`.
    var transportRaw: String?

    var providerID: String?
    /// Where the tab works. Its workspace sets it, and it then follows the
    /// tab as it reports moving: an agent that moves into a worktree stays
    /// there across a relaunch, and a terminal reopens wherever it last was
    /// unless that folder is gone. `TabDirectoryStore` owns the live value and
    /// writes through here.
    var workingDirectoryPath: String?
    var workspaceKindRaw: String = WorkspaceKind.unset.rawValue
    /// The repository `workingDirectoryPath` belongs to; nil outside git.
    var repoPath: String?
    /// The branch the tab's workspace was made on or switched to. Unlike
    /// `workingDirectoryPath` it never follows the tab, so it still names a
    /// worktree Plume made after the tab has moved out of it.
    var branchName: String?
    /// False only for a tab saved before tabs owned their workspace, until
    /// `TabWorkspaceMigration` fills it from its task. The initializer sets
    /// it, so the stored default reaches only those older tabs.
    var isWorkspaceMigrated: Bool = false
    /// The CLI's own identifier for this conversation, passed back to it to
    /// resume: a Claude Code `session_id`, or a Codex `threadId`.
    var agentSessionID: String?
    /// An agent tab that has ever held a session; see `WorkTask.hasNeverStarted`.
    var hasAgentSession: Bool { kind == .agent && agentSessionID != nil }
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

    var devicePlatformRaw: String? = nil

    /// The AVD id of an emulator, the adb serial of a physical device, or a remote device's reservation id.
    var deviceIdentifier: String? = nil

    /// The Google Cloud project a remote device was reserved in.
    var remoteProjectID: String? = nil
    /// `codename/api`, kept so an ended reservation can be reserved again.
    var remoteDeviceModel: String? = nil
    var remoteExpiresAt: Date? = nil

    /// A chat tab's unread mark: the ID of the conversation's latest message
    /// when the mark was set. Nil reads as read. `UnreadPersistence` owns it.
    var unreadMessageID: String? = nil

    /// The tab's status as of `StatusPersistence`'s last debounced snapshot.
    /// Read back at launch through `TaskStatus.afterRelaunch`.
    var lastStatusRaw: String = TaskStatus.notStarted.rawValue

    /// Reserved for extra launch args and statusline preferences.
    var launchArgumentsData: Data?
    /// JSON `[String]` of absolute paths passed as `--add-dir`. A resume
    /// restores none of a session's added folders, so this is the only
    /// record of them. `AdditionalDirectoryStore` owns the writes to a tab
    /// with a session; a fork copies its source's list before it has one.
    var additionalDirectoriesData: Data?
    /// JSON `[String]` of folders removed from this tab. A resumed session
    /// can go on reporting a folder it reached before, and this keeps that
    /// report from adopting it again.
    var removedAdditionalDirectoriesData: Data?
    /// The tab whose agent started this one as a child session, or empty.
    /// `docs/child-sessions.md` is the reference.
    var parentTabIDRaw: String = ""

    init(kind: TabKind, orderIndex: Int, task: WorkTask? = nil) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.orderIndex = orderIndex
        self.task = task
        self.providerID = kind == .agent ? ClaudeCodeProviderID : nil
        self.isWorkspaceMigrated = true
    }

    var workspaceKind: WorkspaceKind {
        get { WorkspaceKind(rawValue: workspaceKindRaw) ?? .unset }
        set { workspaceKindRaw = newValue.rawValue }
    }

    var workspace: TabWorkspace {
        get {
            TabWorkspace(kind: workspaceKind, directory: workingDirectoryPath, repoPath: repoPath, branchName: branchName)
        }
        set {
            workspaceKind = newValue.kind
            workingDirectoryPath = newValue.directory
            repoPath = newValue.repoPath
            branchName = newValue.branchName
        }
    }

    var kind: TabKind {
        get { TabKind(rawValue: kindRaw) ?? .agent }
        set { kindRaw = newValue.rawValue }
    }

    var lastStatus: TaskStatus {
        get { TaskStatus(migratingRawValue: lastStatusRaw) }
        set { lastStatusRaw = newValue.rawValue }
    }

    var devicePlatform: DevicePlatform? {
        get { devicePlatformRaw.flatMap(DevicePlatform.init(rawValue:)) }
        set { devicePlatformRaw = newValue?.rawValue }
    }

    var deviceTarget: DeviceTarget? {
        DeviceTarget(platform: devicePlatform, identifier: deviceIdentifier)
    }

    var isEmulatorTab: Bool {
        kind == .device && deviceTarget?.isPhysical == false
    }

    var isRemoteDeviceTab: Bool {
        guard kind == .device, case .remote = deviceTarget else { return false }
        return true
    }

    var remoteDetails: RemoteDeviceDetails? {
        guard let remoteProjectID else { return nil }
        return RemoteDeviceDetails(projectID: remoteProjectID, model: remoteDeviceModel, expiresAt: remoteExpiresAt)
    }

    func setDevice(_ target: DeviceTarget?, displayName: String?) {
        devicePlatform = target?.platform
        deviceIdentifier = target?.identifier
        title = displayName
        if target?.platform != .androidRemote { setRemoteDetails(nil) }
    }

    func setRemoteDetails(_ details: RemoteDeviceDetails?) {
        remoteProjectID = details?.projectID
        remoteDeviceModel = details?.model
        remoteExpiresAt = details?.expiresAt
    }

    var titleSource: TitleSource? {
        get { titleSourceRaw.flatMap(TitleSource.init(rawValue:)) }
        set { titleSourceRaw = newValue?.rawValue }
    }

    /// The source to seed on launch or unarchive. A tab with no session to
    /// resume starts a new conversation, which must be free to title itself
    /// even if Start Fresh left the old conversation's title behind.
    var restorableTitleSource: TitleSource? {
        agentSessionID == nil ? nil : titleSource
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

    var parentTabID: UUID? {
        get { UUID(uuidString: parentTabIDRaw) }
        set { parentTabIDRaw = newValue?.uuidString ?? "" }
    }

    var additionalDirectories: [String] {
        get {
            guard let additionalDirectoriesData else { return [] }
            return AdditionalDirectories.decoded(additionalDirectoriesData)
        }
        set {
            additionalDirectoriesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    var removedAdditionalDirectories: [String] {
        get {
            guard let removedAdditionalDirectoriesData else { return [] }
            return AdditionalDirectories.decoded(removedAdditionalDirectoriesData)
        }
        set {
            removedAdditionalDirectoriesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
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
        switch kind {
        case .agent: return "Agent"
        case .terminal: return "Terminal"
        case .device: return "Device"
        }
    }
}

nonisolated struct TabWorkspace: Equatable, Sendable {
    var kind: WorkspaceKind = .unset
    var directory: String?
    var repoPath: String?
    var branchName: String?

    static func directory(_ path: String, repoPath: String? = nil, branchName: String? = nil) -> TabWorkspace {
        TabWorkspace(kind: .directory, directory: path, repoPath: repoPath, branchName: branchName)
    }
}

nonisolated let ClaudeCodeProviderID = AgentProviderKind.claudeCode.rawValue

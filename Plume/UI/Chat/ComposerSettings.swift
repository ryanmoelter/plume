import Foundation

/// Where the composer's model / effort / permission-mode controls read and
/// write, on either side of a tab's first message.
///
/// A tab has no session until `AgentLauncher` starts one, and the launch reads
/// `tab.model` / `tab.effort` / `tab.permissionMode`. So before launch the
/// controls are the tab's, and the value they write is what the launch uses;
/// after launch they are the session's, which owns the live conversation and
/// is corrected from the stream.
@MainActor
struct ComposerSettings {
    private let session: HeadlessSession?
    private let tab: TaskTab

    init(session: HeadlessSession?, tab: TaskTab) {
        self.session = session
        self.tab = tab
    }

    /// True while the displayed values are the tab's stored guess rather than
    /// a running conversation's own state.
    var isPreLaunch: Bool { session == nil }

    var model: AgentModel? { session?.model ?? tab.model }
    var effort: AgentEffort? { session?.effort ?? tab.effort }
    var permissionMode: PermissionMode? {
        session.map(\.permissionMode) ?? tab.permissionMode
    }

    /// Mode and model are both corrected by the `init` event, so until it
    /// lands the displayed pair is a guess: the tab's snapshot before launch,
    /// and the value the launch asked for until the CLI answers. Effort is
    /// excluded — nothing ever reports it back, so it would dim forever.
    var isModeAndModelUnconfirmed: Bool {
        session?.hasReportedModeAndModel != true
    }

    func modeAndModelHelp(_ label: String) -> String {
        isModeAndModelUnconfirmed ? "\(label) (not yet confirmed by Claude Code)" : label
    }

    func setModel(_ model: AgentModel) {
        tab.model = model
        session?.setModel(model)
    }

    func setEffort(_ effort: AgentEffort) {
        tab.effort = effort
        session?.setEffort(effort)
    }

    func setPermissionMode(_ mode: PermissionMode) {
        tab.permissionMode = mode
        session?.setPermissionMode(mode)
    }
}

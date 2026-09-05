import Foundation

/// Where the composer's model / effort / permission-mode controls read and
/// write, on either side of a tab's first message.
///
/// A tab has no session until `AgentLauncher` starts one, and the launch reads
/// `tab.model` / `tab.effort` / `tab.permissionMode`. So before launch the
/// controls are the tab's, and the value they write is what the launch uses;
/// after launch they are the session's, which owns the live conversation and
/// is corrected from the stream.
///
/// A tab that has chosen nothing still runs on *something*, so an unset
/// control displays the value the launch will resolve to rather than a blank.
/// Displaying a default never writes one: the tab stays unset until the user
/// picks, which is what keeps `--model` off the command line.
@MainActor
struct ComposerSettings {
    /// What each control falls back to when neither the session nor the tab
    /// has a value — the same resolution the launch performs.
    struct Defaults {
        var permissionMode: PermissionMode?
        var effort: AgentEffort
        var model: AgentModel?

        /// Reads the app's settings and, through them, the CLI's own.
        @MainActor
        static func resolved(task: WorkTask?) -> Defaults {
            let settings = AppSettings.shared
            return Defaults(
                permissionMode: AgentLauncher.resolvedPermissionMode(
                    tab: nil,
                    task: task?.permissionMode,
                    appDefault: settings.resolvedDefaultPermissionMode
                ),
                effort: settings.defaultEffort,
                model: settings.resolvedDefaultModel
            )
        }
    }

    private let session: (any AgentSession)?
    private let tab: TaskTab
    private let defaults: Defaults

    init(session: (any AgentSession)?, tab: TaskTab, defaults: Defaults) {
        self.session = session
        self.tab = tab
        self.defaults = defaults
    }

    /// True while the displayed values are the tab's stored guess rather than
    /// a running conversation's own state.
    var isPreLaunch: Bool { session == nil }

    var model: AgentModel? { session?.model ?? tab.model ?? defaults.model }
    var effort: AgentEffort { session?.effort ?? tab.effort ?? defaults.effort }
    var permissionMode: PermissionMode? {
        session.map(\.permissionMode) ?? tab.permissionMode ?? defaults.permissionMode
    }

    var provider: AgentProviderKind { tab.provider }
    var models: [AgentModel] { provider.models }
    var efforts: [AgentEffort] { provider.efforts }
    var permissionPreset: AgentPermissionPreset? {
        if provider == .claudeCode {
            return permissionMode.map { .init(id: $0.rawValue, label: $0.label) }
        }
        return tab.permissionPreset ?? .codexWorkspace
    }

    /// True when the displayed value is a resolved default rather than a
    /// choice, so a control can label it as one.
    var isModelDefaulted: Bool { session?.model == nil && tab.model == nil }

    /// What a launch passing no `--model` lands on, for the menu's Default
    /// item to name.
    var defaultModel: AgentModel? { defaults.model }

    /// Mode and model are both corrected by the `init` event, so until it
    /// lands the displayed pair is a guess: the tab's snapshot before launch,
    /// and the value the launch asked for until the CLI answers. Effort is
    /// excluded — nothing ever reports it back, so it would dim forever.
    var isModeAndModelUnconfirmed: Bool {
        session?.hasReportedModeAndModel != true
    }

    /// True only while a *running* session has yet to report. Before launch
    /// there is nothing to disagree with the displayed value, so dimming it
    /// would read as a disabled control rather than a pending one.
    var isModelAwaitingConfirmation: Bool {
        session != nil && isModeAndModelUnconfirmed
    }

    func modeAndModelHelp(_ label: String) -> String {
        isModeAndModelUnconfirmed ? "\(label) (not yet confirmed by \(provider.displayName))" : label
    }

    func setModel(_ model: AgentModel) {
        tab.model = model
        tab.isModelUserChosen = true
        session?.setModel(model)
    }

    /// Returns the tab to running on whatever the CLI resolves for itself, so
    /// no `--model` reaches the command line. A running session cannot be
    /// un-pinned — it is already on some model — so it is switched to the
    /// resolved default instead.
    func clearModel() {
        tab.model = nil
        tab.isModelUserChosen = false
        if let session, let fallback = defaults.model {
            session.setModel(fallback)
        }
    }

    func setEffort(_ effort: AgentEffort) {
        tab.effort = effort
        session?.setEffort(effort)
    }

    func setPermissionMode(_ mode: PermissionMode) {
        tab.permissionMode = mode
        session?.setPermissionMode(mode)
    }

    func setPermissionPreset(_ preset: AgentPermissionPreset) {
        tab.permissionPreset = preset
        if provider == .claudeCode, let mode = PermissionMode(rawValue: preset.id) {
            session?.setPermissionMode(mode)
        } else if let session = session as? CodexSession {
            session.setPermissionProfile(preset)
        }
    }
}

import Foundation

/// A permission mode this UI can start a session in, per `claude --help`.
///
/// The CLI also accepts `dontAsk`, which is deliberately absent from this
/// enum, so `recognizing(_:)` returns nil for a session running in it and the
/// UI shows the reported string rather than a wrong selection.
///
/// `bypassPermissions` stays in the enum even though the picker hides it by
/// default (`AppSettings.showsBypassPermissions`): a session already running
/// in it, or a task/tab that stored it before the setting existed, still has
/// to decode and display correctly.
nonisolated enum PermissionMode: String, CaseIterable, Identifiable {
    case plan
    case auto
    case acceptEdits
    case manual
    case bypassPermissions

    var id: String { rawValue }

    /// The `--permission-mode` argument.
    var token: String { rawValue }

    var label: String {
        switch self {
        case .plan: return "Plan"
        case .manual: return "Manual"
        case .acceptEdits: return "Accept Edits"
        case .auto: return "Auto"
        case .bypassPermissions: return "Bypass Permissions"
        }
    }

    /// The cases the picker offers, given whether bypass is unlocked.
    static func offered(showsBypassPermissions: Bool) -> [PermissionMode] {
        allCases.filter { $0 != .bypassPermissions || showsBypassPermissions }
    }

    /// Maps a transcript-reported `permissionMode` back to an option, or nil
    /// for a mode this UI does not offer.
    static func recognizing(_ reported: String) -> PermissionMode? {
        PermissionMode(rawValue: reported)
    }
}

/// The permission mode a new agent tab starts in, as a Plume setting.
///
/// `.followClaudeCode` is the default: it defers to whatever the user has
/// already configured in `~/.claude/settings.json` rather than picking a
/// mode on their behalf. The other cases pin a specific `PermissionMode`.
nonisolated enum PermissionModeDefault: String, CaseIterable, Identifiable {
    case followClaudeCode
    case plan
    case auto
    case acceptEdits
    case manual
    case bypassPermissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followClaudeCode: return "Follow Claude Code"
        case .plan: return PermissionMode.plan.label
        case .manual: return PermissionMode.manual.label
        case .acceptEdits: return PermissionMode.acceptEdits.label
        case .auto: return PermissionMode.auto.label
        case .bypassPermissions: return PermissionMode.bypassPermissions.label
        }
    }

    /// The pinned mode, or nil for `.followClaudeCode`.
    var permissionMode: PermissionMode? {
        switch self {
        case .followClaudeCode: return nil
        case .plan: return .plan
        case .manual: return .manual
        case .acceptEdits: return .acceptEdits
        case .auto: return .auto
        case .bypassPermissions: return .bypassPermissions
        }
    }

    /// The cases the "New agent tabs start in" picker offers, given whether
    /// bypass is unlocked. A previously stored `.bypassPermissions` default
    /// still decodes and resolves via `permissionMode` even while hidden here.
    static func offered(showsBypassPermissions: Bool) -> [PermissionModeDefault] {
        allCases.filter { $0 != .bypassPermissions || showsBypassPermissions }
    }
}

import Foundation

/// A permission mode this UI can start a session in, per `claude --help`.
///
/// The CLI also accepts `manual` and `dontAsk`; both are deliberately absent
/// from the menu, so `recognizing(_:)` returns nil for a session running in
/// one and the UI shows the reported string rather than a wrong selection.
nonisolated enum PermissionMode: String, CaseIterable, Identifiable {
    case plan
    case acceptEdits
    case auto
    case bypassPermissions

    var id: String { rawValue }

    /// The `--permission-mode` argument.
    var token: String { rawValue }

    var label: String {
        switch self {
        case .plan: return "Plan"
        case .acceptEdits: return "Accept Edits"
        case .auto: return "Auto"
        case .bypassPermissions: return "Bypass Permissions"
        }
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
    case acceptEdits
    case auto
    case bypassPermissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followClaudeCode: return "Follow Claude Code"
        case .plan: return PermissionMode.plan.label
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
        case .acceptEdits: return .acceptEdits
        case .auto: return .auto
        case .bypassPermissions: return .bypassPermissions
        }
    }
}

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

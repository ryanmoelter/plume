import Foundation

/// The permission mode a child session starts in.
nonisolated enum ChildSessionPermissions {
    /// `approvedByUser` is true when the user approved this start, through
    /// the permission prompt or a card's click. Without it, a parent not in
    /// bypass cannot start a bypass child, which gets auto instead.
    static func mode(
        requested: PermissionMode?,
        parent: PermissionMode,
        showsBypassPermissions: Bool,
        approvedByUser: Bool
    ) -> Result<PermissionMode, ChildSessionError> {
        guard parent != .plan else { return .failure(.parentInPlanMode) }
        let mode = requested ?? parent
        guard mode == .bypassPermissions else { return .success(mode) }
        let allowed = showsBypassPermissions && (parent == .bypassPermissions || approvedByUser)
        return .success(allowed ? .bypassPermissions : .auto)
    }

    /// Whether starting the session needs the user's approval: it asks for
    /// bypass, which the parent does not have. A parent in bypass passes it
    /// on as it is.
    static func needsApproval(
        requested: PermissionMode?, parent: PermissionMode?, showsBypassPermissions: Bool
    ) -> Bool {
        showsBypassPermissions && requested == .bypassPermissions && parent != .bypassPermissions
    }

    /// The `permission_mode` a `start_session` call names, if Plume
    /// recognizes it.
    static func requested(in arguments: [String: JSONValue]) -> PermissionMode? {
        arguments["permission_mode"]?.stringValue
            .flatMap { PermissionMode.recognizing($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

import Foundation

/// The permission mode a child session starts in. A child never runs with
/// more freedom than its parent has at the moment it starts the child.
nonisolated enum ChildSessionPermissions {
    /// Strictest first.
    static let ordered: [PermissionMode] = [.plan, .manual, .acceptEdits, .auto, .bypassPermissions]

    static func mode(
        requested: PermissionMode?,
        parent: PermissionMode,
        showsBypassPermissions: Bool
    ) -> Result<PermissionMode, ChildSessionError> {
        guard parent != .plan else {
            return .failure(.failed("This session is in plan mode, so it cannot start sessions. Exit plan mode first."))
        }
        var mode = requested ?? parent
        if rank(of: mode) > rank(of: parent) { mode = parent }
        if mode == .bypassPermissions, !showsBypassPermissions { mode = .auto }
        return .success(mode)
    }

    private static func rank(of mode: PermissionMode) -> Int {
        ordered.firstIndex(of: mode) ?? 0
    }
}

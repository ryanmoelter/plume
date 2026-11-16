import Foundation

/// The permission mode a child session starts in.
nonisolated enum ChildSessionPermissions {
    static func mode(
        requested: PermissionMode?,
        parent: PermissionMode,
        showsBypassPermissions: Bool
    ) -> Result<PermissionMode, ChildSessionError> {
        guard parent != .plan else { return .failure(.parentInPlanMode) }
        var mode = requested ?? parent
        if mode == .bypassPermissions, !showsBypassPermissions { mode = .auto }
        return .success(mode)
    }
}

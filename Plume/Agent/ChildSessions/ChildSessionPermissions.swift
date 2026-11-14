import Foundation

/// The permission mode a child session starts in, and how far it may be
/// raised later. A child never runs with more freedom than its parent has,
/// unless it already ran with more before the parent's mode dropped.
nonisolated enum ChildSessionPermissions {
    /// Strictest first.
    static let ordered: [PermissionMode] = [.plan, .manual, .acceptEdits, .auto, .bypassPermissions]

    static func mode(
        requested: PermissionMode?,
        parent: PermissionMode,
        showsBypassPermissions: Bool
    ) -> Result<PermissionMode, ChildSessionError> {
        guard parent != .plan else { return .failure(.parentInPlanMode) }
        var mode = requested ?? parent
        if rank(of: mode) > rank(of: parent) { mode = parent }
        if mode == .bypassPermissions, !showsBypassPermissions { mode = .auto }
        return .success(mode)
    }

    /// The highest mode a raise the user did not pick may reach: the
    /// parent's mode, or the child's launch mode once the parent is gone.
    /// A parent in plan mode still lets an approved plan start work.
    static func ceiling(parent: PermissionMode?, launchedWith: PermissionMode, showsBypassPermissions: Bool) -> PermissionMode {
        var ceiling = parent ?? launchedWith
        if ceiling == .plan { ceiling = .manual }
        if ceiling == .bypassPermissions, !showsBypassPermissions { ceiling = .auto }
        return ceiling
    }

    /// `mode`, or the ceiling when `mode` is above it. A cap never lowers
    /// the session below `current`, which the user may have picked.
    static func capped(_ mode: PermissionMode, at ceiling: PermissionMode, current: PermissionMode? = nil) -> PermissionMode {
        guard rank(of: mode) > rank(of: ceiling) else { return mode }
        guard let current, rank(of: current) > rank(of: ceiling) else { return ceiling }
        return current
    }

    static func allows(_ mode: PermissionMode, under ceiling: PermissionMode) -> Bool {
        rank(of: mode) <= rank(of: ceiling)
    }

    private static func rank(of mode: PermissionMode) -> Int {
        ordered.firstIndex(of: mode) ?? 0
    }
}

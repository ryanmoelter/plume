import Foundation

/// Decides what the picker shows when a `set_permission_mode` reply arrives.
///
/// The picker moves optimistically, so a refusal has to put it back on the
/// mode the CLI actually kept. Replies arrive in request order, so only the
/// latest request's refusal reverts; an older one's would undo a newer choice.
/// The revert goes to the last mode the CLI confirmed rather than the one
/// showing before the refused request, which may itself have been refused.
nonisolated struct PermissionModeRequests {
    enum Outcome: Equatable {
        case keep
        case revert(to: PermissionMode?)
    }

    private(set) var confirmed: PermissionMode?
    private var latestRequestID: String?

    /// Records a mode the CLI reports as current: the launch mode, or `init`.
    mutating func confirm(_ mode: PermissionMode?) {
        confirmed = mode
    }

    mutating func didRequest(id: String) {
        latestRequestID = id
    }

    mutating func applyReply(requestID: String, mode: PermissionMode, isError: Bool) -> Outcome {
        let isLatest = requestID == latestRequestID
        if isLatest { latestRequestID = nil }
        guard isError else {
            confirmed = mode
            return .keep
        }
        return isLatest ? .revert(to: confirmed) : .keep
    }
}

import Foundation

/// A permission mode the CLI reported as current.
nonisolated enum ReportedPermissionMode: Equatable {
    case known(PermissionMode)
    /// A mode Plume has no case for, such as `default` or `dontAsk`, so
    /// nothing it allows can be assumed.
    case unrecognized(String)

    var known: PermissionMode? {
        if case .known(let mode) = self { mode } else { nil }
    }
}

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

    /// The last recognized mode the CLI confirmed, which a refusal reverts to.
    private(set) var confirmed: PermissionMode?
    /// The mode the CLI last confirmed, recognized or not. Unlike the
    /// picker's mode, it never moves before the CLI agrees.
    private(set) var reported: ReportedPermissionMode?
    private var latestRequestID: String?

    /// Records a mode the CLI reports as current: the launch mode, `init`,
    /// a `status` line or an accepted suggestion.
    mutating func confirm(_ mode: PermissionMode) {
        confirmed = mode
        reported = .known(mode)
    }

    /// Records whatever the CLI reported. A mode Plume does not recognize
    /// leaves `confirmed`, and so the picker, on the last recognized one.
    mutating func confirm(reported token: String) {
        if let mode = PermissionMode.recognizing(token) {
            confirm(mode)
        } else {
            reported = .unrecognized(token)
        }
    }

    mutating func didRequest(id: String) {
        latestRequestID = id
    }

    mutating func applyReply(requestID: String, mode: PermissionMode, isError: Bool) -> Outcome {
        let isLatest = requestID == latestRequestID
        if isLatest { latestRequestID = nil }
        guard isError else {
            confirm(mode)
            return .keep
        }
        return isLatest ? .revert(to: confirmed) : .keep
    }
}

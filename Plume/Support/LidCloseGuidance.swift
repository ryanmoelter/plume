import Foundation

/// What to tell the user about closing the lid, given what the Mac will
/// actually do.
///
/// No power assertion survives a lid close. The one thing that does is the
/// `SleepDisabled` override the `PlumeSleepHelper` daemon sets, so the
/// guidance follows the helper's state rather than the hardware's clamshell
/// keys, which report clamshell mode on an open laptop.
enum LidCloseGuidance: Equatable, Sendable {
    /// Closing the lid sleeps the Mac; the override is off or not yet usable.
    case sleepsOnLidClose
    /// The override is on and approved, and will engage with the next hold.
    case staysAwakeWhileHolding
    /// The override is engaged right now.
    case staysAwakeViaHelper
    /// The helper is registered but waits on Login Items.
    case helperNeedsApproval
    /// The helper failed, with the reason.
    case helperUnavailable(String)
    /// Never mode, so nothing to say.
    case notApplicable

    static func resolve(
        mode: KeepAwakeMode,
        wantsLidClosed: Bool,
        override: LidSleepOverrideStatus
    ) -> LidCloseGuidance {
        // Never mode already means the user does not want Plume touching
        // sleep, so lid advice would be noise.
        guard mode != .never else { return .notApplicable }

        switch override {
        case .engaged:
            return .staysAwakeViaHelper
        case .needsApproval:
            return .helperNeedsApproval
        case .unavailable(let reason):
            return .helperUnavailable(reason)
        case .ready where wantsLidClosed:
            return .staysAwakeWhileHolding
        case .ready, .notRegistered:
            return .sleepsOnLidClose
        }
    }

    /// The panel's one-line statement of what the lid does right now.
    var summary: String? {
        switch self {
        case .sleepsOnLidClose:
            "Closing the lid sleeps the Mac and pauses every agent."
        case .staysAwakeWhileHolding:
            "The lid can stay closed whenever Plume is holding this Mac awake."
        case .staysAwakeViaHelper:
            "The lid can stay closed — Plume is holding this Mac awake."
        case .helperNeedsApproval:
            "Plume's sleep helper needs your approval in Login Items."
        case .helperUnavailable(let reason):
            reason
        case .notApplicable:
            nil
        }
    }

    /// What the user can do about it, when there is something.
    var explanation: String? {
        switch self {
        case .sleepsOnLidClose:
            "Turn on “Keep awake with the lid closed” to override this. "
                + "It installs a helper that needs a one-time admin approval."
        case .helperNeedsApproval:
            "Allow Plume under “Allow in the Background”, then come back."
        default:
            nil
        }
    }

    /// Whether to offer the System Settings shortcut, which only helps when
    /// the lid is what will stop the work.
    var offersSystemSettings: Bool { self == .sleepsOnLidClose }

    /// Whether to offer the Login Items shortcut.
    var offersLoginItems: Bool { self == .helperNeedsApproval }
}

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
    /// The helper has never been registered; the lid sleeps the Mac until it is.
    case helperNotInstalled
    /// The helper failed, with the reason.
    case helperUnavailable(String)
    /// The override would otherwise be in effect, but the Mac is running hot
    /// enough to trip the thermal cutoff.
    case pausedForHeat
    /// Never mode, so nothing to say.
    case notApplicable

    static func resolve(
        mode: KeepAwakeMode,
        wantsLidClosed: Bool,
        override: LidSleepOverrideStatus,
        pausedForHeat: Bool = false
    ) -> LidCloseGuidance {
        // Never mode already means the user does not want Plume touching
        // sleep, so lid advice would be noise.
        guard mode != .never else { return .notApplicable }

        if wantsLidClosed, pausedForHeat {
            return .pausedForHeat
        }

        switch override {
        case .engaged:
            return .staysAwakeViaHelper
        case .needsApproval:
            return .helperNeedsApproval
        case .unavailable(let reason):
            return .helperUnavailable(reason)
        case .ready where wantsLidClosed:
            return .staysAwakeWhileHolding
        case .notRegistered:
            return .helperNotInstalled
        case .ready:
            return .sleepsOnLidClose
        }
    }

    /// The one line the panel shows, when there is anything worth saying.
    var note: String? {
        switch self {
        case .staysAwakeWhileHolding, .staysAwakeViaHelper:
            "Connect to your phone hotspot, throw your laptop in your bag, "
                + "and know that Plume will put it to sleep if it gets too hot."
        case .pausedForHeat:
            "Paused while the Mac is running hot."
        case .helperUnavailable(let reason):
            reason
        case .sleepsOnLidClose, .helperNeedsApproval, .helperNotInstalled, .notApplicable:
            nil
        }
    }

    /// Whether to offer the install button, which stands in for any text.
    var offersInstall: Bool { self == .helperNotInstalled }

    /// Whether to offer the Login Items shortcut.
    var offersLoginItems: Bool { self == .helperNeedsApproval }
}

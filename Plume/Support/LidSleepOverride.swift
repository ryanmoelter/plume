import Foundation

/// Where the lid-closed override stands, from "no helper" to "in effect".
enum LidSleepOverrideStatus: Equatable, Sendable {
    /// The helper has never been registered with launchd.
    case notRegistered
    /// Registered, and waiting for the user to allow it in Login Items.
    case needsApproval
    /// Approved and reachable, but not currently overriding sleep.
    case ready
    /// `SleepDisabled` is set, so a lid close will not sleep the Mac.
    case engaged
    /// Registration or the helper itself failed, with the reason to show.
    case unavailable(String)

    /// Whether an `apply(true)` can take effect right now.
    var canEngage: Bool { self == .ready || self == .engaged }
}

/// The seam over the privileged helper, so the coordinator and the panel are
/// testable without launchd, root, or a lid.
///
/// `SleepAssertion` covers idle sleep; this covers the one thing no assertion
/// can, which is a lid close. It is a modifier on a hold, never a reason of
/// its own.
@MainActor
protocol LidSleepOverride: AnyObject {
    var status: LidSleepOverrideStatus { get }

    /// Registers the helper if it never was. Registration pushes a System
    /// Settings prompt, so callers do this only once the user has asked.
    func ensureRegistered()

    /// Sets or clears the override. Idempotent, like `SleepAssertion.apply`.
    func apply(_ engaged: Bool)

    /// Re-reads registration state, for the panel opening or the app coming
    /// back from System Settings.
    func refreshStatus()
}

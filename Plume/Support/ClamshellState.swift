import Foundation

/// Whether closing the lid would sleep this Mac.
///
/// No power assertion survives a lid close — `kIOPMAssertPreventUserIdleSystemSleep`
/// documents that the system still sleeps for it, and the one type that sounded
/// like it would, `kIOPMAssertionTypePreventSystemSleep`, is unsupported and
/// deprecated. What actually decides this is the hardware's own clamshell mode,
/// which macOS exposes read-only as `AppleClamshellCausesSleep`.
enum ClamshellSleepBehavior: Equatable, Sendable {
    /// Closing the lid sleeps the Mac, whatever Plume asks for.
    case sleeps
    /// The Mac stays awake with the lid closed — clamshell mode, which needs an
    /// external display and, on Apple laptops, power.
    case staysAwake
    /// A Mac with no lid, so the question does not arise.
    case noClamshell

    /// Whether the keep-awake UI should warn that a lid close ends the session.
    var warnsAboutLidClose: Bool { self == .sleeps }
}

/// Reads the clamshell keys `IOPMrootDomain` publishes.
///
/// A seam rather than a direct read so the panel's guidance is testable on any
/// machine, including the desktops and CI hosts that have no lid at all.
@MainActor
protocol ClamshellStateReading: AnyObject {
    var behavior: ClamshellSleepBehavior { get }
    /// Re-reads from the system. Cheap enough to call when the panel opens.
    func refresh()
}

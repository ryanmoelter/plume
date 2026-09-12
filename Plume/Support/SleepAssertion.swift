import Foundation

enum SleepAssertionType: Equatable, Sendable {
    /// Defers idle sleep. The display still dims and sleeps, and the Mac
    /// still sleeps for lid close, low battery, and the Apple menu.
    case preventIdleSystemSleep
    /// What Apple documents for a host serving remote clients. Also holds the
    /// Mac in dark wake, which idle-sleep prevention does not, but applies
    /// only on AC power.
    case networkClientActive
}

/// What the Mac is being held awake as, and why.
///
/// The reason is user-visible — it appears in `pmset -g assertions` and in
/// the battery menu's energy list — so it reads as a sentence, not a symbol.
struct SleepAssertionRequest: Equatable, Sendable {
    var type: SleepAssertionType
    var reason: String

    /// `IOPMAssertionCreateWithName` takes a name of at most 128 characters.
    static let reasonLimit = 128

    init(type: SleepAssertionType, reason: String) {
        self.type = type
        self.reason = String(reason.prefix(Self.reasonLimit))
    }
}

/// The seam over IOKit, so everything above it is testable without touching
/// power management.
@MainActor
protocol SleepAssertion: AnyObject {
    /// What is held right now, or nil when the Mac is free to sleep.
    var held: SleepAssertionRequest? { get }
    func apply(_ request: SleepAssertionRequest?)
}

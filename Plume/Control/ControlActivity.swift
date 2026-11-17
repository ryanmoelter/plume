#if DEBUG
import Foundation

nonisolated enum ControlActivity {
    /// A driven instance is never frontmost, and App Nap would otherwise
    /// throttle its timers into timings no user sees. End it with
    /// `ProcessInfo.endActivity(_:)`.
    static func begin(reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: reason)
    }
}
#endif
